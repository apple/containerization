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

    // MARK: - Primitives

    @Test("Test entryType reports each kind without following symlinks")
    func testEntryType() throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }
        try Data("x".utf8).write(to: URL(fileURLWithPath: rootPath.appending("file").string))
        try FileManager.default.createDirectory(atPath: rootPath.appending("dir").string, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: rootPath.appending("link").string, withDestinationPath: "dir")
        #expect(mkfifo(rootPath.appending("fifo").string, 0o644) == 0)

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        let file: FileDescriptorOps.EntryType? = try FileDescriptorOps.entryType(rootFd, "file")
        let dir: FileDescriptorOps.EntryType? = try FileDescriptorOps.entryType(rootFd, "dir")
        let link: FileDescriptorOps.EntryType? = try FileDescriptorOps.entryType(rootFd, "link")
        let fifo: FileDescriptorOps.EntryType? = try FileDescriptorOps.entryType(rootFd, "fifo")
        let missing: FileDescriptorOps.EntryType? = try FileDescriptorOps.entryType(rootFd, "missing")
        #expect(file == .regular)
        #expect(dir == .directory)
        #expect(link == .symlink, "a symlink to a directory is reported as a symlink")
        #expect(fifo == .other)
        #expect(missing == nil)
    }

    @Test("Test openDirectory opens directories and classifies what is in the way")
    func testOpenDirectory() throws {
        let basePath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: basePath.string) }
        let rootPath = basePath.appending("root")
        try FileManager.default.createDirectory(atPath: rootPath.appending("dir").string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: basePath.appending("outside").string, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: rootPath.appending("file").string))
        try FileManager.default.createSymbolicLink(atPath: rootPath.appending("link").string, withDestinationPath: "../outside")

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        let opened = try FileDescriptorOps.openDirectory(rootFd, "dir")
        defer { try? opened.close() }
        #expect(fcntl(opened.rawValue, F_GETFD) & FD_CLOEXEC != 0)

        #expect(throws: FileDescriptorOps.Error.notFound) { _ = try FileDescriptorOps.openDirectory(rootFd, "missing") }
        #expect(throws: FileDescriptorOps.Error.cannotFollowSymlink) { _ = try FileDescriptorOps.openDirectory(rootFd, "link") }
        #expect(throws: FileDescriptorOps.Error.conflict(.regular)) { _ = try FileDescriptorOps.openDirectory(rootFd, "file") }
    }

    @Test("Test makeDirectory creates a directory and refuses to touch anything that exists")
    func testMakeDirectory() throws {
        let basePath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: basePath.string) }
        let rootPath = basePath.appending("root")
        try FileManager.default.createDirectory(atPath: rootPath.appending("dir").string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: basePath.appending("outside").string, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: rootPath.appending("file").string))
        try FileManager.default.createSymbolicLink(atPath: rootPath.appending("link").string, withDestinationPath: "../outside")

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        try FileDescriptorOps.makeDirectory(rootFd, "new", permissions: FilePermissions(rawValue: 0o700))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: rootPath.appending("new").string, isDirectory: &isDirectory) && isDirectory.boolValue)

        for name in ["dir", "file", "link"] as [FilePath.Component] {
            #expect(throws: FileDescriptorOps.Error.alreadyExists) { try FileDescriptorOps.makeDirectory(rootFd, name) }
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rootPath.appending("link").string) == "../outside")
        #expect(try FileManager.default.contentsOfDirectory(atPath: basePath.appending("outside").string).isEmpty)
    }

    @Test("Test unlink removes files and symlinks but never directories or symlink targets")
    func testUnlink() throws {
        let basePath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: basePath.string) }
        let rootPath = basePath.appending("root")
        let outsidePath = basePath.appending("outside")
        try FileManager.default.createDirectory(atPath: rootPath.appending("dir").string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outsidePath.string, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: outsidePath.appending("target").string))
        try Data("x".utf8).write(to: URL(fileURLWithPath: rootPath.appending("file").string))
        try FileManager.default.createSymbolicLink(atPath: rootPath.appending("link").string, withDestinationPath: "../outside/target")

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        try FileDescriptorOps.unlink(rootFd, "file")
        try FileDescriptorOps.unlink(rootFd, "link")
        #expect(!FileManager.default.fileExists(atPath: rootPath.appending("file").string))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rootPath.string) == ["dir"])
        #expect(FileManager.default.fileExists(atPath: outsidePath.appending("target").string), "the target of a removed symlink must be untouched")

        #expect(throws: FileDescriptorOps.Error.notFound) { try FileDescriptorOps.unlink(rootFd, "missing") }
        #expect(throws: (any Swift.Error).self) { try FileDescriptorOps.unlink(rootFd, "dir") }
        #expect(FileManager.default.fileExists(atPath: rootPath.appending("dir").string), "unlink must not remove a directory")
    }

    // MARK: - Leaf primitives

    private struct Sandbox {
        let base: FilePath
        let root: FilePath
        let outside: FilePath
        let rootFd: FileDescriptor

        func cleanup() {
            try? rootFd.close()
            try? FileManager.default.removeItem(atPath: base.string)
        }
    }

    /// A temporary `root` to work in, with a sibling `outside` that nothing may touch.
    private func makeSandbox() throws -> Sandbox {
        let base = try createTempDirectory()
        let root = base.appending("root")
        let outside = base.appending("outside")
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: outside.string, withIntermediateDirectories: false)
        let rootFd = try FileDescriptor.open(root, .readOnly, options: [.directory])
        return Sandbox(base: base, root: root, outside: outside, rootFd: rootFd)
    }

    private func writeText(_ text: String, to path: FilePath) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path.string))
    }

    @Test("Test status reports metadata without following symlinks")
    func testStatus() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        try writeText("hello", to: sandbox.root.appending("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sandbox.root.appending("file").string)
        try FileManager.default.createSymbolicLink(atPath: sandbox.root.appending("link").string, withDestinationPath: "file")

        let file = try #require(try FileDescriptorOps.status(sandbox.rootFd, "file"))
        #expect(file.type == .regular)
        #expect(file.size == 5)
        #expect(file.permissions.rawValue & 0o777 == 0o640)
        #expect(file.userID == geteuid())
        #expect(file.modificationSeconds > 0)

        let link = try #require(try FileDescriptorOps.status(sandbox.rootFd, "link"))
        #expect(link.type == .symlink, "status describes the link itself, not its target")
        #expect(try FileDescriptorOps.status(sandbox.rootFd, "missing") == nil)

        let rootStatus = try FileDescriptorOps.status(of: sandbox.rootFd)
        #expect(rootStatus.type == .directory)
    }

    @Test("Test openFile reads a regular file and refuses everything else")
    func testOpenFile() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        try writeText("secret", to: sandbox.outside.appending("target"))
        try writeText("hello", to: sandbox.root.appending("file"))
        try FileManager.default.createDirectory(atPath: sandbox.root.appending("dir").string, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: sandbox.root.appending("link").string, withDestinationPath: "../outside/target")
        #expect(mkfifo(sandbox.root.appending("fifo").string, 0o644) == 0)

        let fd = try FileDescriptorOps.openFile(sandbox.rootFd, "file")
        defer { try? fd.close() }
        #expect(fcntl(fd.rawValue, F_GETFD) & FD_CLOEXEC != 0)
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = read(fd.rawValue, &buffer, buffer.count)
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == "hello")

        #expect(throws: FileDescriptorOps.Error.notFound) { _ = try FileDescriptorOps.openFile(sandbox.rootFd, "missing") }
        #expect(throws: FileDescriptorOps.Error.cannotFollowSymlink) { _ = try FileDescriptorOps.openFile(sandbox.rootFd, "link") }
        #expect(throws: FileDescriptorOps.Error.conflict(.directory)) { _ = try FileDescriptorOps.openFile(sandbox.rootFd, "dir") }
        // Opening a FIFO for reading would block forever if it were opened blocking.
        #expect(throws: FileDescriptorOps.Error.conflict(.other)) { _ = try FileDescriptorOps.openFile(sandbox.rootFd, "fifo") }
    }

    @Test("Test createFile creates exclusively and never writes through or over anything")
    func testCreateFile() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        try writeText("keep", to: sandbox.outside.appending("target"))
        try writeText("old", to: sandbox.root.appending("file"))
        try FileManager.default.createDirectory(atPath: sandbox.root.appending("dir").string, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: sandbox.root.appending("link").string, withDestinationPath: "../outside/target")

        let fd = try FileDescriptorOps.createFile(sandbox.rootFd, "new", permissions: FilePermissions(rawValue: 0o600))
        defer { try? fd.close() }
        #expect(fcntl(fd.rawValue, F_GETFD) & FD_CLOEXEC != 0)
        #expect(write(fd.rawValue, "data", 4) == 4)
        #expect(try String(contentsOfFile: sandbox.root.appending("new").string, encoding: .utf8) == "data")

        for name in ["file", "dir", "link"] as [FilePath.Component] {
            #expect(throws: FileDescriptorOps.Error.alreadyExists) { _ = try FileDescriptorOps.createFile(sandbox.rootFd, name) }
        }
        #expect(try String(contentsOfFile: sandbox.root.appending("file").string, encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: sandbox.outside.appending("target").string, encoding: .utf8) == "keep", "nothing may be written through a symlink")
    }

    @Test("Test makeSymlink and readSymlink round-trip any target without following it")
    func testSymlinks() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        try writeText("x", to: sandbox.root.appending("file"))
        let longTarget = String(repeating: "a/", count: 300)

        let targets = ["relative", "../outside/escape", "/etc/passwd", longTarget]
        for (index, target) in targets.enumerated() {
            let name = try #require(FilePath.Component("link\(index)"))
            try FileDescriptorOps.makeSymlink(sandbox.rootFd, name, target: target)
            #expect(try FileDescriptorOps.readSymlink(sandbox.rootFd, name) == target)
            #expect(try FileDescriptorOps.entryType(sandbox.rootFd, name) == .symlink)
        }

        #expect(throws: FileDescriptorOps.Error.alreadyExists) { try FileDescriptorOps.makeSymlink(sandbox.rootFd, "file", target: "y") }
        #expect(throws: FileDescriptorOps.Error.alreadyExists) { try FileDescriptorOps.makeSymlink(sandbox.rootFd, "link0", target: "y") }
        #expect(throws: FileDescriptorOps.Error.conflict(.regular)) { _ = try FileDescriptorOps.readSymlink(sandbox.rootFd, "file") }
        #expect(throws: FileDescriptorOps.Error.notFound) { _ = try FileDescriptorOps.readSymlink(sandbox.rootFd, "missing") }
    }

    // MARK: - Reading beneath a directory

    @Test("Test openFile(relativePath:) reads nested files and refuses symlinks, parents that are not directories, and bad paths")
    func testOpenFileRelativePath() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        try writeText("secret", to: sandbox.outside.appending("target"))
        try FileManager.default.createDirectory(atPath: sandbox.outside.appending("dir").string, withIntermediateDirectories: false)
        try writeText("secret", to: sandbox.outside.appending("dir/target"))
        try FileManager.default.createDirectory(atPath: sandbox.root.appending("a/b").string, withIntermediateDirectories: true)
        try writeText("nested", to: sandbox.root.appending("a/b/file"))
        try writeText("plain", to: sandbox.root.appending("plain"))
        try FileManager.default.createSymbolicLink(atPath: sandbox.root.appending("filelink").string, withDestinationPath: "../outside/target")
        try FileManager.default.createSymbolicLink(atPath: sandbox.root.appending("dirlink").string, withDestinationPath: "../outside/dir")
        try FileManager.default.createSymbolicLink(atPath: sandbox.root.appending("a/up").string, withDestinationPath: "../../outside/dir")

        let fd = try FileDescriptorOps.openFile(sandbox.rootFd, relativePath: "a/b/file")
        defer { try? fd.close() }
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = read(fd.rawValue, &buffer, buffer.count)
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == "nested")

        let cases: [(String, FileDescriptorOps.Error)] = [
            ("filelink", .cannotFollowSymlink),
            ("dirlink/target", .cannotFollowSymlink),
            ("a/up/target", .cannotFollowSymlink),
            ("plain/x", .conflict(.regular)),
            ("a/b/missing", .notFound),
            ("missing/file", .notFound),
            ("a/b", .conflict(.directory)),
            ("../outside/target", .invalidRelativePath),
            ("a/../../outside/target", .invalidRelativePath),
            ("/etc/hosts", .invalidRelativePath),
            ("", .invalidRelativePath),
        ]
        for (path, expected) in cases {
            #expect(throws: expected, "\(path)") { _ = try FileDescriptorOps.openFile(sandbox.rootFd, relativePath: FilePath(path)) }
        }
    }

    @Test("Test status(relativePath:) describes entries beneath a directory and refuses symlinks in parent positions")
    func testStatusRelativePath() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        try FileManager.default.createDirectory(atPath: sandbox.outside.appending("dir").string, withIntermediateDirectories: false)
        try writeText("x", to: sandbox.outside.appending("dir/target"))
        try FileManager.default.createDirectory(atPath: sandbox.root.appending("a/b").string, withIntermediateDirectories: true)
        try writeText("nested", to: sandbox.root.appending("a/b/file"))
        try writeText("plain", to: sandbox.root.appending("plain"))
        try FileManager.default.createSymbolicLink(atPath: sandbox.root.appending("dirlink").string, withDestinationPath: "../outside/dir")

        #expect(try FileDescriptorOps.status(sandbox.rootFd, relativePath: "a/b/file")?.type == .regular)
        #expect(try FileDescriptorOps.status(sandbox.rootFd, relativePath: "a/b/file")?.size == 6)
        #expect(try FileDescriptorOps.status(sandbox.rootFd, relativePath: "a/b")?.type == .directory)
        #expect(try FileDescriptorOps.status(sandbox.rootFd, relativePath: "dirlink")?.type == .symlink, "the link itself")
        #expect(try FileDescriptorOps.status(sandbox.rootFd, relativePath: "")?.type == .directory, "an empty path is the directory itself")
        #expect(try FileDescriptorOps.status(sandbox.rootFd, relativePath: "a/b/missing") == nil)
        #expect(try FileDescriptorOps.status(sandbox.rootFd, relativePath: "missing/file") == nil)

        #expect(throws: FileDescriptorOps.Error.cannotFollowSymlink) { _ = try FileDescriptorOps.status(sandbox.rootFd, relativePath: "dirlink/target") }
        #expect(throws: FileDescriptorOps.Error.conflict(.regular)) { _ = try FileDescriptorOps.status(sandbox.rootFd, relativePath: "plain/x") }
        #expect(throws: FileDescriptorOps.Error.invalidRelativePath) { _ = try FileDescriptorOps.status(sandbox.rootFd, relativePath: "../outside") }
        #expect(throws: FileDescriptorOps.Error.invalidRelativePath) { _ = try FileDescriptorOps.status(sandbox.rootFd, relativePath: "/etc") }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }
    }

    @Test("Test openFile(relativePath:) never reads outside the root while components are swapped for symlinks")
    func testOpenFileRaceNeverEscapes() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        try writeText("SECRET", to: sandbox.outside.appending("bait"))
        try FileManager.default.createDirectory(atPath: sandbox.root.appending("dir").string, withIntermediateDirectories: false)
        try writeText("SAFE", to: sandbox.root.appending("dir/bait"))

        let root = sandbox.root.string
        let outside = sandbox.outside.string
        let stop = StopFlag()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let fm = FileManager.default
            while !stop.isSet {
                // Swap the last component between a regular file and a symlink to the secret.
                try? fm.removeItem(atPath: "\(root)/dir/bait")
                try? fm.createSymbolicLink(atPath: "\(root)/dir/bait", withDestinationPath: "\(outside)/bait")
                try? fm.removeItem(atPath: "\(root)/dir/bait")
                try? Data("SAFE".utf8).write(to: URL(fileURLWithPath: "\(root)/dir/bait"))
                // Swap the parent directory between a real directory and a symlink to the outside.
                try? fm.moveItem(atPath: "\(root)/dir", toPath: "\(root)/dir.hold")
                try? fm.createSymbolicLink(atPath: "\(root)/dir", withDestinationPath: outside)
                try? fm.removeItem(atPath: "\(root)/dir")
                try? fm.moveItem(atPath: "\(root)/dir.hold", toPath: "\(root)/dir")
            }
            finished.signal()
        }

        var leaked = false
        var opened = 0
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            guard let fd = try? FileDescriptorOps.openFile(sandbox.rootFd, relativePath: "dir/bait") else {
                continue
            }
            var buffer = [UInt8](repeating: 0, count: 16)
            let count = read(fd.rawValue, &buffer, buffer.count)
            try? fd.close()
            if String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == "SECRET" {
                leaked = true
            }
            opened += 1
        }
        stop.set()
        finished.wait()

        #expect(!leaked, "a file outside the root was read through a swapped symlink")
        #expect(opened > 0, "the test never managed to open the file, so it proved nothing")
    }

    // MARK: - mkdir replaces what is in the way

    @Test("Test mkdir replaces a file or symlink that is in the way, and never writes through a symlink")
    func testMkdirReplacesWhatIsInTheWay() throws {
        struct Case {
            let name: String
            let path: String
            let setup: (_ root: FilePath, _ outside: FilePath) throws -> Void
        }
        let writeFile: (FilePath, FilePath) throws -> Void = { root, _ in
            try Data("old".utf8).write(to: URL(fileURLWithPath: root.appending("f").string))
        }
        let writeLink: (FilePath, FilePath) throws -> Void = { root, outside in
            try FileManager.default.createSymbolicLink(atPath: root.appending("l").string, withDestinationPath: outside.string)
        }
        let cases = [
            Case(name: "file at the last component", path: "f", setup: writeFile),
            Case(name: "symlink at the last component", path: "l", setup: writeLink),
            Case(name: "file at an intermediate component", path: "f/x", setup: writeFile),
            Case(name: "symlink at an intermediate component", path: "l/x", setup: writeLink),
        ]

        for testCase in cases {
            let basePath = try createTempDirectory()
            defer { try? FileManager.default.removeItem(atPath: basePath.string) }
            let rootPath = basePath.appending("root")
            let outsidePath = basePath.appending("outside")
            try FileManager.default.createDirectory(atPath: rootPath.string, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: outsidePath.string, withIntermediateDirectories: false)
            try testCase.setup(rootPath, outsidePath)

            let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
            defer { try? rootFd.close() }

            var completionCalled = false
            try FileDescriptorOps.mkdir(rootFd, FilePath(testCase.path), makeIntermediates: true) { _ in
                completionCalled = true
            }

            #expect(completionCalled, "\(testCase.name)")
            let first = String(testCase.path.split(separator: "/")[0])
            let kind = try FileManager.default.attributesOfItem(atPath: rootPath.appending(first).string)[.type] as? FileAttributeType
            #expect(kind == .typeDirectory, "\(testCase.name): what was in the way must be replaced by a directory")
            #expect(try FileManager.default.contentsOfDirectory(atPath: outsidePath.string).isEmpty, "\(testCase.name): nothing may be created outside the root")
        }
    }

    @Test("Test mkdir without makeIntermediates leaves what is in the way of an intermediate directory alone")
    func testMkdirWithoutIntermediatesLeavesWhatIsInTheWay() throws {
        let basePath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: basePath.string) }
        let rootPath = basePath.appending("root")
        let outsidePath = basePath.appending("outside")
        try FileManager.default.createDirectory(atPath: rootPath.string, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: outsidePath.string, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: URL(fileURLWithPath: rootPath.appending("f").string))
        try FileManager.default.createSymbolicLink(atPath: rootPath.appending("l").string, withDestinationPath: outsidePath.string)

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        for path in ["f/x", "l/x"] {
            #expect(throws: FileDescriptorOps.Error.invalidPathComponent, "\(path)") {
                try FileDescriptorOps.mkdir(rootFd, FilePath(path))
            }
        }

        #expect(try String(contentsOfFile: rootPath.appending("f").string, encoding: .utf8) == "old")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rootPath.appending("l").string) == outsidePath.string)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outsidePath.string).isEmpty)
    }

    @Test("Test mkdir replaces a symlink with a directory and never writes through it")
    func testMkdirReplacesSymlinkAndNeverWritesThrough() throws {
        let basePath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: basePath.string) }
        let rootPath = basePath.appending("root")
        let outsidePath = basePath.appending("outside")
        try FileManager.default.createDirectory(atPath: rootPath.string, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: outsidePath.string, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: rootPath.appending("l").string, withDestinationPath: outsidePath.string)

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        try FileDescriptorOps.mkdir(rootFd, FilePath("l/x"), makeIntermediates: true) { dirFd in
            let fd = openat(dirFd.rawValue, "stub", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            #expect(fd >= 0)
            if fd >= 0 { close(fd) }
        }

        #expect(FileManager.default.fileExists(atPath: rootPath.appending("l/x/stub").string))
        #expect(try FileManager.default.attributesOfItem(atPath: rootPath.appending("l").string)[.type] as? FileAttributeType == .typeDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outsidePath.string).isEmpty, "nothing may be written through the replaced symlink")
    }

    @Test("Test mkdir never removes a directory it cannot open", .enabled(if: geteuid() != 0))
    func testMkdirDoesNotRemoveUnopenableDirectory() throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }
        let lockedPath = rootPath.appending("locked")
        try FileManager.default.createDirectory(atPath: lockedPath.string, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: lockedPath.appending("keep").string))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedPath.string)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        #expect(throws: (any Swift.Error).self) {
            try FileDescriptorOps.mkdir(rootFd, FilePath("locked/child"), makeIntermediates: true)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedPath.string)
        #expect(FileManager.default.fileExists(atPath: lockedPath.appending("keep").string), "a directory that cannot be opened must not be removed")
    }

    @Test("Test mkdir rejects an absolute path and creates nothing")
    func testMkdirRejectsAbsolutePath() throws {
        let basePath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: basePath.string) }

        let rootPath = basePath.appending("root")
        let targetPath = basePath.appending("absolute-target")
        try FileManager.default.createDirectory(atPath: rootPath.string, withIntermediateDirectories: false)

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        for makeIntermediates in [false, true] {
            var completionCalled = false
            #expect(throws: FileDescriptorOps.Error.invalidRelativePath) {
                try FileDescriptorOps.mkdir(rootFd, targetPath.appending("child"), makeIntermediates: makeIntermediates) { _ in
                    completionCalled = true
                }
            }
            #expect(!completionCalled)
        }

        // Nothing is created at the absolute location, or re-anchored under the root.
        #expect(!FileManager.default.fileExists(atPath: targetPath.string))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rootPath.string).isEmpty)
    }

    @Test("Test directory descriptors opened by mkdir are close-on-exec")
    func testMkdirDescriptorsAreCloseOnExec() throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        var completionCalled = false
        try FileDescriptorOps.mkdir(rootFd, FilePath("a/b/c"), makeIntermediates: true) { dirFd in
            completionCalled = true
            let flags = fcntl(dirFd.rawValue, F_GETFD)
            #expect(flags >= 0)
            #expect(flags & FD_CLOEXEC != 0, "descriptor handed to completion must be close-on-exec")
        }
        #expect(completionCalled)
    }

    @Test("Test directory descriptors opened by enumerate are close-on-exec")
    func testEnumerateDescriptorsAreCloseOnExec() throws {
        let rootPath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: rootPath.string) }
        try FileManager.default.createDirectory(
            atPath: rootPath.appending("a/b").string, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: rootPath.appending("a/b/file.txt").string))

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        // Entries below the top level are reported with a descriptor that enumerate opened itself.
        var checked = 0
        try FileDescriptorOps.enumerate(rootFd) { path, _, parentFd in
            guard path.components.count > 1 else { return }
            let flags = fcntl(parentFd.rawValue, F_GETFD)
            #expect(flags >= 0)
            #expect(flags & FD_CLOEXEC != 0, "descriptor for \(path.string) must be close-on-exec")
            checked += 1
        }
        #expect(checked == 2)  // a/b and a/b/file.txt
    }

    @Test("Test unlinkRecursive removes a nested tree without following symlinks")
    func testUnlinkRecursiveDoesNotFollowSymlinks() throws {
        let basePath = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: basePath.string) }

        let rootPath = basePath.appending("root")
        let outsidePath = basePath.appending("outside")
        try FileManager.default.createDirectory(atPath: rootPath.appending("tree/sub").string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outsidePath.string, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: outsidePath.appending("keep.txt").string))
        try FileManager.default.createSymbolicLink(
            atPath: rootPath.appending("tree/sub/link").string, withDestinationPath: outsidePath.string)

        let rootFd = try FileDescriptor.open(rootPath, .readOnly, options: [.directory])
        defer { try? rootFd.close() }

        let name = FilePath.Component("tree")
        try FileDescriptorOps.unlinkRecursive(rootFd, filename: name)

        #expect(!FileManager.default.fileExists(atPath: rootPath.appending("tree").string))
        #expect(FileManager.default.fileExists(atPath: outsidePath.appending("keep.txt").string))
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
