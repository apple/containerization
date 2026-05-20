//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import SystemPackage
import Testing

@testable import ContainerizationOS

#if canImport(Darwin)
import Darwin
let os_close = Darwin.close
#elseif canImport(Musl)
import Musl
let os_close = Musl.close
#elseif canImport(Glibc)
import Glibc
let os_close = Glibc.close
#endif

struct FileDescriptorPathSecureTests {
    @Test(
        "Test creation of stub file under directory successfully created by secure mkdir",
        arguments: [
            // Case 1: Single component, no intermediates needed, default permissions
            ([Entry](), FilePath("foo"), nil as FilePermissions?, false),

            // Case 2: Single component with explicit permissions
            ([Entry](), FilePath("foo"), FilePermissions(rawValue: 0o755), false),

            // Case 3: Two components, parent exists, no intermediates
            ([Entry.directory(path: "foo")], FilePath("foo/bar"), nil as FilePermissions?, false),

            // Case 4: Two components, parent missing, makeIntermediates true
            ([Entry](), FilePath("foo/bar"), nil as FilePermissions?, true),

            // Case 5: Three components, makeIntermediates true, custom permissions
            ([Entry](), FilePath("foo/bar/baz"), FilePermissions(rawValue: 0o700), true),

            // Case 6: Replace existing file with directory (single component)
            ([Entry.regular(path: "foo")], FilePath("foo"), nil as FilePermissions?, false),

            // Case 7: Replace existing file with directory path (makeIntermediates true)
            ([Entry.regular(path: "foo")], FilePath("foo/bar"), nil as FilePermissions?, true),

            // Case 8: Replace existing directory with new directory (should be idempotent)
            ([Entry.directory(path: "foo")], FilePath("foo"), nil as FilePermissions?, false),

            // Case 9: Replace nested directory structure
            (
                [
                    Entry.directory(path: "foo/bar"),
                    Entry.regular(path: "foo/bar/file.txt"),
                ], FilePath("foo/bar"), nil as FilePermissions?, false
            ),

            // Case 10: Replace symlink with directory
            ([Entry.symlink(target: "target", source: "foo")], FilePath("foo"), nil as FilePermissions?, false),

            // Case 11: Multi-level with some intermediates existing
            ([Entry.directory(path: "foo")], FilePath("foo/bar/baz"), nil as FilePermissions?, true),

            // Case 12: Deep nesting with makeIntermediates
            ([Entry](), FilePath("a/b/c/d/e"), nil as FilePermissions?, true),
        ]
    )
    func testMkdirSecureValid(entries: [Entry], relativePath: FilePath, permissions: FilePermissions?, makeIntermediates: Bool) async throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }
        try createEntries(rootPath: rootPath, entries: entries, permissions: permissions)
        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        let stubFileName = "stub.txt"
        let stubContent = Data("stub file content".utf8)

        try FileDescriptorOps.mkdir(rootFd, relativePath, permissions: permissions, makeIntermediates: makeIntermediates) { dirFd in
            // Create a stub file in the directory using openat
            let fd = openat(
                dirFd.rawValue,
                stubFileName,
                O_WRONLY | O_CREAT | O_TRUNC,
                0o644
            )
            guard fd >= 0 else {
                throw Errno(rawValue: errno)
            }
            defer { close(fd) }

            try stubContent.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let written = write(fd, baseAddress, buffer.count)
                guard written == buffer.count else {
                    throw Errno(rawValue: errno)
                }
            }
        }

        // Check stub file existence at expected location
        let expectedStubPath = rootPath.appending(relativePath.string).appending(stubFileName)
        #expect(FileManager.default.fileExists(atPath: expectedStubPath.string))

        // Verify stub file content
        let readContent = try Data(contentsOf: URL(fileURLWithPath: expectedStubPath.string))
        #expect(readContent == stubContent)

        // Check directory permissions if specified
        if let permissions = permissions {
            // Check each component of the path
            let components = relativePath.components
            var currentPath = ""
            for (index, component) in components.enumerated() {
                if index > 0 {
                    currentPath += "/"
                }
                currentPath += component.string

                let dirPath = rootPath.appending(currentPath)
                let attrs = try FileManager.default.attributesOfItem(atPath: dirPath.string)
                let posixPerms = attrs[.posixPermissions] as? NSNumber
                // Mask to permission bits only (not file type bits)
                let permMask: CModeT = 0o777
                let actualPerms = CModeT(posixPerms?.uint16Value ?? 0) & permMask
                let expectedPerms = permissions.rawValue & permMask
                #expect(
                    actualPerms == expectedPerms,
                    "Directory '\(currentPath)' has permissions 0o\(String(actualPerms, radix: 8)) but expected 0o\(String(expectedPerms, radix: 8))")
            }
        }
    }

    @Test(
        "Test mkdir error cases",
        arguments: [
            // Case 1: Path starting with ".." should be rejected
            (FilePath("../escape"), false, FileDescriptorOps.Error.invalidRelativePath),

            // Case 2: Path with ".." in middle that would escape
            (FilePath("foo/../../escape"), false, FileDescriptorOps.Error.invalidRelativePath),

            // Case 3: Missing intermediate without makeIntermediates should fail
            (FilePath("missing/intermediate/path"), false, FileDescriptorOps.Error.invalidPathComponent),

            // Case 4: Multiple .. that escape
            (FilePath("a/b/../../../escape"), false, FileDescriptorOps.Error.invalidRelativePath),
        ]
    )
    func testMkdirSecureInvalid(relativePath: FilePath, makeIntermediates: Bool, expectedError: FileDescriptorOps.Error) async throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Attempt the operation and expect it to throw
        #expect {
            try FileDescriptorOps.mkdir(rootFd, relativePath, makeIntermediates: makeIntermediates) { _ in }
        } throws: { error in
            guard let securePathError = error as? FileDescriptorOps.Error else {
                return false
            }
            // Compare error cases
            switch (securePathError, expectedError) {
            case (.invalidRelativePath, .invalidRelativePath),
                (.invalidPathComponent, .invalidPathComponent),
                (.cannotFollowSymlink, .cannotFollowSymlink):
                return true
            case (.systemError(let op1, let err1), .systemError(let op2, let err2)):
                return op1 == op2 && err1 == err2
            default:
                return false
            }
        }
    }

    @Test(
        "Test paths with .. that normalize to valid paths",
        arguments: [
            // Paths with .. that should normalize and succeed
            ("./safe", "safe"),  // Leading ./ normalizes to safe
            ("./a/./b", "a/b"),  // Multiple ./ normalize away
        ]
    )
    func testPathsWithDotNormalization(path: String, expectedNormalized: String) async throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        let stubFileName = "stub.txt"
        let stubContent = Data("stub file content".utf8)

        try FileDescriptorOps.mkdir(rootFd, FilePath(path), makeIntermediates: true) { dirFd in
            // Create a stub file to verify we're in the right place
            let fd = openat(
                dirFd.rawValue,
                stubFileName,
                O_WRONLY | O_CREAT | O_TRUNC,
                0o644
            )
            guard fd >= 0 else {
                throw Errno(rawValue: errno)
            }
            defer { close(fd) }

            try stubContent.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let written = write(fd, baseAddress, buffer.count)
                guard written == buffer.count else {
                    throw Errno(rawValue: errno)
                }
            }
        }

        // Verify stub file exists at the normalized location
        let expectedPath =
            expectedNormalized.isEmpty
            ? rootPath.appending(stubFileName)
            : rootPath.appending(expectedNormalized).appending(stubFileName)
        #expect(
            FileManager.default.fileExists(atPath: expectedPath.string),
            "Expected file at normalized path: \(expectedPath.string)")
    }

    @Test(
        "Test paths with .. that normalize to valid paths",
        arguments: [
            // Paths with .. that should fail
            ("safe/.."),  // Normalizes to empty (current dir)
            ("a/../b"),  // Normalizes to b
            ("a/b/../c"),  // Normalizes to a/c
        ]
    )
    func testPathsWithDotDotNormalization(path: String) async throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        #expect(throws: FileDescriptorOps.Error.invalidRelativePath.self) {
            try FileDescriptorOps.mkdir(rootFd, FilePath(path), makeIntermediates: true)
        }
    }

    @Test(
        "Test paths with empty components (double slashes)",
        arguments: [
            "a//b",  // Double slash in middle
            "a///b",  // Triple slash
            "a//b//c",  // Multiple double slashes
        ]
    )
    func testPathsWithEmptyComponents(path: String) async throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        let stubFileName = "stub.txt"
        let stubContent = Data("stub file content".utf8)

        // Should normalize and succeed (// becomes /)
        try FileDescriptorOps.mkdir(rootFd, FilePath(path), makeIntermediates: true) { dirFd in
            let fd = openat(
                dirFd.rawValue,
                stubFileName,
                O_WRONLY | O_CREAT | O_TRUNC,
                0o644
            )
            guard fd >= 0 else {
                throw Errno(rawValue: errno)
            }
            defer { close(fd) }

            try stubContent.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let written = write(fd, baseAddress, buffer.count)
                guard written == buffer.count else {
                    throw Errno(rawValue: errno)
                }
            }
        }

        // Verify the file exists somewhere under root (normalization should handle it)
        // The exact location depends on how FilePath normalizes empty components
        let normalizedPath = FilePath(path).lexicallyNormalized()
        let expectedPath = rootPath.appending(normalizedPath.string).appending(stubFileName)
        #expect(
            FileManager.default.fileExists(atPath: expectedPath.string),
            "Expected file at normalized path: \(expectedPath.string)")
    }

    @Test("Test very deep nesting")
    func testDeepNesting() async throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Create a 100-level deep path
        var deepPath = ""
        for i in 0..<100 {
            if i > 0 { deepPath += "/" }
            deepPath += "level\(i)"
        }

        let stubFileName = "deep.txt"
        let stubContent = Data("deep file".utf8)

        try FileDescriptorOps.mkdir(rootFd, FilePath(deepPath), makeIntermediates: true) { dirFd in
            let fd = openat(
                dirFd.rawValue,
                stubFileName,
                O_WRONLY | O_CREAT | O_TRUNC,
                0o644
            )
            guard fd >= 0 else {
                throw Errno(rawValue: errno)
            }
            defer { close(fd) }

            try stubContent.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let written = write(fd, baseAddress, buffer.count)
                guard written == buffer.count else {
                    throw Errno(rawValue: errno)
                }
            }
        }

        // Verify the deep file exists
        let expectedPath = rootPath.appending(deepPath).appending(stubFileName)
        #expect(FileManager.default.fileExists(atPath: expectedPath.string))
    }

    @Test("Test path with null byte")
    func testNullByteInPath() async throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Path with null byte - FilePath may handle this differently
        // This tests that we don't crash or have unexpected behavior
        let pathWithNull = "file\u{0000}.txt"

        // Try to create it - behavior depends on FilePath's null byte handling
        // We mainly want to ensure it doesn't bypass security checks
        do {
            try FileDescriptorOps.mkdir(rootFd, FilePath(pathWithNull), makeIntermediates: true) { _ in }

            // If it succeeds, verify it stayed within root
            let entries = try FileManager.default.contentsOfDirectory(atPath: rootPath.string)
            for entry in entries {
                let fullPath = rootPath.appending(entry)
                let canonicalRoot = try FileDescriptorOps.getCanonicalPath(rootFd)
                let canonicalEntry = try FileDescriptor.open(fullPath, .readOnly)
                let canonicalEntryPath = try FileDescriptorOps.getCanonicalPath(canonicalEntry)
                try? canonicalEntry.close()

                // Verify entry is under root
                #expect(
                    canonicalEntryPath.string.hasPrefix(canonicalRoot.string + "/") || canonicalEntryPath.string == canonicalRoot.string,
                    "Entry escaped root: \(canonicalEntryPath.string)")
            }
        } catch {
            // If it fails, that's also acceptable - just don't crash
        }
    }

    @Test("Remove a regular file")
    func testRemoveRegularFile() throws {
        let tempPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let rootFd = try FileDescriptor.open(tempPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Create a regular file
        let filePath = tempPath.appending("testfile.txt")
        _ = FileManager.default.createFile(atPath: filePath.string, contents: Data("test".utf8))

        // Verify file exists
        #expect(FileManager.default.fileExists(atPath: filePath.string))

        // Remove it
        try FileDescriptorOps.unlinkRecursive(rootFd, filename: FilePath.Component("testfile.txt"))

        // Verify file is gone
        #expect(!FileManager.default.fileExists(atPath: filePath.string))
    }

    @Test("Remove an empty directory")
    func testRemoveEmptyDirectory() throws {
        let tempPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let rootFd = try FileDescriptor.open(tempPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Create an empty directory
        let dirPath = tempPath.appending("emptydir")
        try FileManager.default.createDirectory(atPath: dirPath.string, withIntermediateDirectories: false)

        // Verify directory exists
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dirPath.string, isDirectory: &isDir))
        #expect(isDir.boolValue)

        // Remove it
        try FileDescriptorOps.unlinkRecursive(rootFd, filename: FilePath.Component("emptydir"))

        // Verify directory is gone
        #expect(!FileManager.default.fileExists(atPath: dirPath.string))
    }

    @Test("Remove a directory with nested files and subdirectories")
    func testRemoveNestedDirectory() throws {
        let tempPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let rootFd = try FileDescriptor.open(tempPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Create nested structure:
        // nested/
        //   file1.txt
        //   subdir/
        //     file2.txt
        //     deepdir/
        //       file3.txt
        let nestedPath = tempPath.appending("nested")
        let subdirPath = nestedPath.appending("subdir")
        let deepdirPath = subdirPath.appending("deepdir")

        try FileManager.default.createDirectory(atPath: deepdirPath.string, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: nestedPath.appending("file1.txt").string, contents: Data("1".utf8))
        _ = FileManager.default.createFile(atPath: subdirPath.appending("file2.txt").string, contents: Data("2".utf8))
        _ = FileManager.default.createFile(atPath: deepdirPath.appending("file3.txt").string, contents: Data("3".utf8))

        // Verify structure exists
        #expect(FileManager.default.fileExists(atPath: nestedPath.string))
        #expect(FileManager.default.fileExists(atPath: subdirPath.string))
        #expect(FileManager.default.fileExists(atPath: deepdirPath.string))

        // Remove entire tree
        try FileDescriptorOps.unlinkRecursive(rootFd, filename: FilePath.Component("nested"))

        // Verify everything is gone
        #expect(!FileManager.default.fileExists(atPath: nestedPath.string))
    }

    @Test("Remove non-existent file returns without error")
    func testRemoveNonExistent() throws {
        let tempPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let rootFd = try FileDescriptor.open(tempPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Remove non-existent file should not throw
        try FileDescriptorOps.unlinkRecursive(rootFd, filename: FilePath.Component("nonexistent.txt"))
    }

    @Test("Remove symlink without following it")
    func testRemoveSymlink() throws {
        let tempPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let rootFd = try FileDescriptor.open(tempPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Create target file and symlink
        let targetPath = tempPath.appending("target.txt")
        let linkPath = tempPath.appending("link")
        _ = FileManager.default.createFile(atPath: targetPath.string, contents: Data("target".utf8))
        try FileManager.default.createSymbolicLink(atPath: linkPath.string, withDestinationPath: "target.txt")

        // Verify both exist
        #expect(FileManager.default.fileExists(atPath: targetPath.string))
        #expect(FileManager.default.fileExists(atPath: linkPath.string))

        // Remove symlink
        try FileDescriptorOps.unlinkRecursive(rootFd, filename: FilePath.Component("link"))

        // Verify symlink is gone but target remains
        #expect(!FileManager.default.fileExists(atPath: linkPath.string))
        #expect(FileManager.default.fileExists(atPath: targetPath.string))
    }

    @Test("Remove directory with mixed content (files, dirs, symlinks)")
    func testRemoveMixedDirectory() throws {
        let tempPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let rootFd = try FileDescriptor.open(tempPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Create mixed structure:
        // mixed/
        //   file.txt
        //   subdir/
        //   link -> file.txt
        let mixedPath = tempPath.appending("mixed")
        let subdirPath = mixedPath.appending("subdir")

        try FileManager.default.createDirectory(atPath: subdirPath.string, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: mixedPath.appending("file.txt").string, contents: Data("test".utf8))
        try FileManager.default.createSymbolicLink(
            atPath: mixedPath.appending("link").string,
            withDestinationPath: "file.txt"
        )

        // Verify structure exists
        #expect(FileManager.default.fileExists(atPath: mixedPath.string))

        // Remove entire tree
        try FileDescriptorOps.unlinkRecursive(rootFd, filename: FilePath.Component("mixed"))

        // Verify everything is gone
        #expect(!FileManager.default.fileExists(atPath: mixedPath.string))
    }

    @Test("Guards against removing '.' component")
    func testGuardDotComponent() throws {
        let tempPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let rootFd = try FileDescriptor.open(tempPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Should return without error and without removing anything
        try FileDescriptorOps.unlinkRecursive(rootFd, filename: FilePath.Component("."))

        // Verify directory still exists
        #expect(FileManager.default.fileExists(atPath: tempPath.string))
    }

    @Test("Guards against removing '..' component")
    func testGuardDotDotComponent() throws {
        let tempPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let rootFd = try FileDescriptor.open(tempPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Should return without error and without removing anything
        try FileDescriptorOps.unlinkRecursive(rootFd, filename: FilePath.Component(".."))

        // Verify directory still exists
        #expect(FileManager.default.fileExists(atPath: tempPath.string))
    }

    @Test("Test mkdir with empty path calls completion with parent")
    func testMkdirEmptyPath() throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        let stubFileName = "root-level-file.txt"
        let stubContent = Data("root level content".utf8)
        var completionCalled = false

        // Call mkdir with empty path
        try FileDescriptorOps.mkdir(rootFd, FilePath(""), makeIntermediates: false) { dirFd in
            completionCalled = true

            // Verify dirFd is the same as rootFd
            #expect(dirFd.rawValue == rootFd.rawValue, "Completion should receive the parent directory FD")

            // Create a file in the directory to verify we got the right FD
            let fd = openat(
                dirFd.rawValue,
                stubFileName,
                O_WRONLY | O_CREAT | O_TRUNC,
                0o644
            )
            guard fd >= 0 else {
                throw Errno(rawValue: errno)
            }
            defer { close(fd) }

            try stubContent.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let written = write(fd, baseAddress, buffer.count)
                guard written == buffer.count else {
                    throw Errno(rawValue: errno)
                }
            }
        }

        // Verify completion was called
        #expect(completionCalled, "Completion handler should be called for empty path")

        // Verify file was created at root level
        let expectedPath = rootPath.appending(stubFileName)
        #expect(FileManager.default.fileExists(atPath: expectedPath.string))

        // Verify content
        let readContent = try Data(contentsOf: URL(fileURLWithPath: expectedPath.string))
        #expect(readContent == stubContent)
    }

    private func createTempDirectory() throws -> FilePath {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        return FilePath(tempURL.path)

    }

    private func createEntries(rootPath: FilePath, entries: [Entry], permissions: FilePermissions? = nil) throws {
        for entry in entries {
            switch entry {
            case .regular(let path):
                let fullPath = rootPath.appending(path)
                // Create parent directories if needed
                let parentPath = FilePath(fullPath.string).removingLastComponent()
                if !FileManager.default.fileExists(atPath: parentPath.string) {
                    try FileManager.default.createDirectory(
                        atPath: parentPath.string,
                        withIntermediateDirectories: true,
                        attributes: permissions.map { [.posixPermissions: $0.rawValue] }
                    )
                }
                _ = FileManager.default.createFile(
                    atPath: fullPath.string,
                    contents: Data("test".utf8)
                )
            case .directory(let path):
                let fullPath = rootPath.appending(path)
                try FileManager.default.createDirectory(
                    atPath: fullPath.string,
                    withIntermediateDirectories: true,
                    attributes: permissions.map { [.posixPermissions: $0.rawValue] }
                )
            case .symlink(let target, let source):
                let sourcePath = rootPath.appending(source)
                // Create parent directories for source if needed
                let parentPath = FilePath(sourcePath.string).removingLastComponent()
                if !FileManager.default.fileExists(atPath: parentPath.string) {
                    try FileManager.default.createDirectory(
                        atPath: parentPath.string,
                        withIntermediateDirectories: true,
                        attributes: permissions.map { [.posixPermissions: $0.rawValue] }
                    )
                }
                try FileManager.default.createSymbolicLink(
                    atPath: sourcePath.string,
                    withDestinationPath: target
                )
            }
        }
    }
}

enum Entry {
    case regular(path: String)
    case directory(path: String)
    case symlink(target: String, source: String)
}

// MARK: - enumerate tests

extension FileDescriptorPathSecureTests {

    // Collect all entries reported by enumerate, keyed by path string.
    private func collect(root: FilePath) throws -> [String: FileDescriptorOps.EntryType] {
        let rootFd = try FileDescriptor.open(root, .readOnly, options: [.directory])
        defer { try? rootFd.close() }
        var found: [String: FileDescriptorOps.EntryType] = [:]
        try FileDescriptorOps.enumerate(rootFd) { path, type, _ in
            found[path.string] = type
        }
        return found
    }

    @Test func testEnumerateSecureEmptyDirectory() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }

        let found = try collect(root: root)
        #expect(found.isEmpty)
    }

    @Test func testEnumerateSecureFlatRegularFiles() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        try createEntries(
            rootPath: root,
            entries: [
                .regular(path: "a.txt"),
                .regular(path: "b.txt"),
                .regular(path: "c.txt"),
            ])

        let found = try collect(root: root)
        #expect(found.count == 3)
        #expect(found["a.txt"] == .regular)
        #expect(found["b.txt"] == .regular)
        #expect(found["c.txt"] == .regular)
    }

    @Test func testEnumerateSecureRecursesIntoRealDirectories() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        try createEntries(
            rootPath: root,
            entries: [
                .directory(path: "subdir"),
                .regular(path: "subdir/file.txt"),
            ])

        let found = try collect(root: root)
        #expect(found.count == 2)
        #expect(found["subdir"] == .directory)
        #expect(found["subdir/file.txt"] == .regular)
    }

    @Test func testEnumerateSecureReportsFileSymlink() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        try createEntries(
            rootPath: root,
            entries: [
                .regular(path: "target.txt"),
                .symlink(target: "target.txt", source: "link.txt"),
            ])

        let found = try collect(root: root)
        #expect(found["link.txt"] == .symlink)
        #expect(found["target.txt"] == .regular)
    }

    @Test func testEnumerateSecureDoesNotFollowDirectorySymlink() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }

        // Create a real directory with content alongside a symlink to it.
        try createEntries(
            rootPath: root,
            entries: [
                .directory(path: "real"),
                .regular(path: "real/inside.txt"),
                .symlink(target: "real", source: "link"),
            ])

        let found = try collect(root: root)
        // "link" is reported as a symlink, not followed — "link/inside.txt" absent.
        #expect(found["link"] == .symlink)
        #expect(found["link/inside.txt"] == nil)
        // The real directory and its content are still traversed normally.
        #expect(found["real"] == .directory)
        #expect(found["real/inside.txt"] == .regular)
    }

    @Test func testEnumerateSecureDoesNotFollowAbsoluteDirectorySymlinkOutside() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }

        // Create a directory entirely outside the root.
        let outside = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: outside.string) }
        #expect(FileManager.default.createFile(atPath: outside.appending("secret.txt").string, contents: Data("secret".utf8)))

        // Symlink inside root → absolute path outside root.
        try createEntries(
            rootPath: root,
            entries: [
                .symlink(target: outside.string, source: "escape")
            ])

        let found = try collect(root: root)
        // The symlink itself is reported…
        #expect(found["escape"] == .symlink)
        // …but nothing inside the outside directory is reachable.
        #expect(found["escape/secret.txt"] == nil)
        #expect(found.count == 1)
    }

    @Test func testEnumerateSecureDoesNotFollowRelativeDirectorySymlinkOutside() throws {
        // Layout: base/root/ and base/outside/, symlink root/escape → ../outside
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let rootStr = (base as NSString).appendingPathComponent("root")
        let outsideStr = (base as NSString).appendingPathComponent("outside")
        try FileManager.default.createDirectory(atPath: rootStr, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outsideStr, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        #expect(FileManager.default.createFile(atPath: (outsideStr as NSString).appendingPathComponent("secret.txt"), contents: Data("secret".utf8)))
        try FileManager.default.createSymbolicLink(
            atPath: (rootStr as NSString).appendingPathComponent("escape"),
            withDestinationPath: "../outside"
        )

        let rootFd = try FileDescriptor.open(FilePath(rootStr), .readOnly, options: [.directory])
        defer { try? rootFd.close() }
        var found: [String: FileDescriptorOps.EntryType] = [:]
        try FileDescriptorOps.enumerate(rootFd) { path, type, _ in found[path.string] = type }

        #expect(found["escape"] == .symlink)
        #expect(found["escape/secret.txt"] == nil)
        #expect(found.count == 1)
    }

    @Test func testEnumerateSecureMixedContent() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        try createEntries(
            rootPath: root,
            entries: [
                .regular(path: "readme.txt"),
                .directory(path: "src"),
                .regular(path: "src/main.swift"),
                .directory(path: "src/util"),
                .regular(path: "src/util/helper.swift"),
                .symlink(target: "readme.txt", source: "link.txt"),
                .symlink(target: "src", source: "src-link"),
            ])

        let found = try collect(root: root)
        #expect(found["readme.txt"] == .regular)
        #expect(found["src"] == .directory)
        #expect(found["src/main.swift"] == .regular)
        #expect(found["src/util"] == .directory)
        #expect(found["src/util/helper.swift"] == .regular)
        #expect(found["link.txt"] == .symlink)
        // Directory symlink: reported but not followed.
        #expect(found["src-link"] == .symlink)
        #expect(found["src-link/main.swift"] == nil)
        #expect(found.count == 7)
    }

    @Test func testEnumerateSecurePreOrderDirectoryBeforeContents() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        try createEntries(
            rootPath: root,
            entries: [
                .directory(path: "dir"),
                .regular(path: "dir/child.txt"),
            ])

        let rootFd = try FileDescriptor.open(root, .readOnly, options: [.directory])
        defer { try? rootFd.close() }
        var order: [String] = []
        try FileDescriptorOps.enumerate(rootFd) { path, _, _ in order.append(path.string) }

        let dirIdx = try #require(order.firstIndex(of: "dir"))
        let childIdx = try #require(order.firstIndex(of: "dir/child.txt"))
        #expect(dirIdx < childIdx, "directory must be reported before its contents")
    }

    @Test func testEnumerateSecureParentFdCanOpenEntryWithoutFollowingSymlinks() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let content = Data("hello".utf8)
        try createEntries(rootPath: root, entries: [.regular(path: "file.txt")])
        #expect(FileManager.default.createFile(atPath: root.appending("file.txt").string, contents: content))

        let rootFd = try FileDescriptor.open(root, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        var readContent: Data?
        try FileDescriptorOps.enumerate(rootFd) { path, type, parentFd in
            guard type == .regular, let name = path.lastComponent?.string else { return }
            // Open through the fd chain — no absolute path involved.
            let fd = openat(parentFd.rawValue, name, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { return }
            defer { _ = os_close(fd) }
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(fd, &buf, buf.count)
            if n > 0 { readContent = Data(buf.prefix(n)) }
        }

        #expect(readContent == content)
    }
}
