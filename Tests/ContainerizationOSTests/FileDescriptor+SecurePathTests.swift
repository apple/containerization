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

        try rootFd.mkdirSecure(relativePath, permissions: permissions, makeIntermediates: makeIntermediates) { dirFd in
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
                let permMask: UInt16 = 0o777
                let actualPerms = (posixPerms?.uint16Value ?? 0) & permMask
                let expectedPerms = permissions.rawValue & permMask
                #expect(
                    actualPerms == expectedPerms,
                    "Directory '\(currentPath)' has permissions 0o\(String(actualPerms, radix: 8)) but expected 0o\(String(expectedPerms, radix: 8))")
            }
        }
    }

    @Test(
        "Test mkdirSecure error cases",
        arguments: [
            // Case 1: Path starting with ".." should be rejected
            (FilePath("../escape"), false, SecurePathError.invalidRelativePath),

            // Case 2: Path with ".." in middle that would escape
            (FilePath("foo/../../escape"), false, SecurePathError.invalidRelativePath),

            // Case 3: Missing intermediate without makeIntermediates should fail
            (FilePath("missing/intermediate/path"), false, SecurePathError.invalidPathComponent),

            // Case 4: Multiple .. that escape
            (FilePath("a/b/../../../escape"), false, SecurePathError.invalidRelativePath),
        ]
    )
    func testMkdirSecureInvalid(relativePath: FilePath, makeIntermediates: Bool, expectedError: SecurePathError) async throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Attempt the operation and expect it to throw
        #expect {
            try rootFd.mkdirSecure(relativePath, makeIntermediates: makeIntermediates) { _ in }
        } throws: { error in
            guard let securePathError = error as? SecurePathError else {
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

        try rootFd.mkdirSecure(FilePath(path), makeIntermediates: true) { dirFd in
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

        #expect(throws: SecurePathError.invalidRelativePath.self) {
            try rootFd.mkdirSecure(FilePath(path), makeIntermediates: true)
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
        try rootFd.mkdirSecure(FilePath(path), makeIntermediates: true) { dirFd in
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

        try rootFd.mkdirSecure(FilePath(deepPath), makeIntermediates: true) { dirFd in
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
            try rootFd.mkdirSecure(FilePath(pathWithNull), makeIntermediates: true) { _ in }

            // If it succeeds, verify it stayed within root
            let entries = try FileManager.default.contentsOfDirectory(atPath: rootPath.string)
            for entry in entries {
                let fullPath = rootPath.appending(entry)
                let canonicalRoot = try rootFd.getCanonicalPath()
                let canonicalEntry = try FileDescriptor.open(fullPath, .readOnly)
                let canonicalEntryPath = try canonicalEntry.getCanonicalPath()
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
        FileManager.default.createFile(atPath: filePath.string, contents: Data("test".utf8))

        // Verify file exists
        #expect(FileManager.default.fileExists(atPath: filePath.string))

        // Remove it
        try rootFd.unlinkRecursiveSecure(filename: FilePath.Component("testfile.txt"))

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
        try rootFd.unlinkRecursiveSecure(filename: FilePath.Component("emptydir"))

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
        FileManager.default.createFile(atPath: nestedPath.appending("file1.txt").string, contents: Data("1".utf8))
        FileManager.default.createFile(atPath: subdirPath.appending("file2.txt").string, contents: Data("2".utf8))
        FileManager.default.createFile(atPath: deepdirPath.appending("file3.txt").string, contents: Data("3".utf8))

        // Verify structure exists
        #expect(FileManager.default.fileExists(atPath: nestedPath.string))
        #expect(FileManager.default.fileExists(atPath: subdirPath.string))
        #expect(FileManager.default.fileExists(atPath: deepdirPath.string))

        // Remove entire tree
        try rootFd.unlinkRecursiveSecure(filename: FilePath.Component("nested"))

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
        try rootFd.unlinkRecursiveSecure(filename: FilePath.Component("nonexistent.txt"))
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
        FileManager.default.createFile(atPath: targetPath.string, contents: Data("target".utf8))
        try FileManager.default.createSymbolicLink(atPath: linkPath.string, withDestinationPath: "target.txt")

        // Verify both exist
        #expect(FileManager.default.fileExists(atPath: targetPath.string))
        #expect(FileManager.default.fileExists(atPath: linkPath.string))

        // Remove symlink
        try rootFd.unlinkRecursiveSecure(filename: FilePath.Component("link"))

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
        FileManager.default.createFile(atPath: mixedPath.appending("file.txt").string, contents: Data("test".utf8))
        try FileManager.default.createSymbolicLink(
            atPath: mixedPath.appending("link").string,
            withDestinationPath: "file.txt"
        )

        // Verify structure exists
        #expect(FileManager.default.fileExists(atPath: mixedPath.string))

        // Remove entire tree
        try rootFd.unlinkRecursiveSecure(filename: FilePath.Component("mixed"))

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
        try rootFd.unlinkRecursiveSecure(filename: FilePath.Component("."))

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
        try rootFd.unlinkRecursiveSecure(filename: FilePath.Component(".."))

        // Verify directory still exists
        #expect(FileManager.default.fileExists(atPath: tempPath.string))
    }

    @Test("Test mkdirSecure with empty path calls completion with parent")
    func testMkdirSecureEmptyPath() throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        let stubFileName = "root-level-file.txt"
        let stubContent = Data("root level content".utf8)
        var completionCalled = false

        // Call mkdirSecure with empty path
        try rootFd.mkdirSecure(FilePath(""), makeIntermediates: false) { dirFd in
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
                FileManager.default.createFile(
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
