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

@testable import ContainerizationArchive

struct ArchiveReaderTests {
    // MARK: - Helper Methods

    func createTestArchive(name: String, entries: [(path: String, type: EntryType, target: String?)]) throws -> URL {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveReaderTests")!
        let archiveURL = testDirectory.appendingPathComponent("\(name).tar")

        let archiver = try ArchiveWriter(format: .paxRestricted, filter: .none, file: archiveURL)

        for entry in entries {
            let writeEntry = WriteEntry()
            writeEntry.path = entry.path
            writeEntry.permissions = 0o644
            writeEntry.owner = 1000
            writeEntry.group = 1000

            switch entry.type {
            case .regular(let content):
                writeEntry.fileType = .regular
                let data = content.data(using: .utf8)!
                writeEntry.size = numericCast(data.count)
                try archiver.writeEntry(entry: writeEntry, data: data)
            case .directory:
                writeEntry.fileType = .directory
                writeEntry.permissions = 0o755
                writeEntry.size = 0
                try archiver.writeEntry(entry: writeEntry, data: nil)
            case .symlink:
                guard let target = entry.target else {
                    throw ArchiveError.failedToExtractArchive("symlink requires target")
                }
                writeEntry.fileType = .symbolicLink
                writeEntry.symlinkTarget = target
                writeEntry.size = 0
                try archiver.writeEntry(entry: writeEntry, data: nil)
            }
        }

        try archiver.finishEncoding()
        return archiveURL
    }

    func createExtractionDirectory(name: String) throws -> URL {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveReaderTests.\(name)")!
        return testDirectory.appendingPathComponent("extract")
    }

    enum EntryType {
        case regular(String)  // Content
        case directory
        case symlink
    }

    // MARK: - Benign Archive Tests

    @Test func extractBenignArchive() throws {
        let archiveURL = try createTestArchive(
            name: "benign",
            entries: [
                ("dir/", .directory, nil),
                ("dir/file.txt", .regular("test content"), nil),
                ("dir/subdir/", .directory, nil),
                ("dir/subdir/file2.txt", .regular("more content"), nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "benign")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty, "Benign archive should not reject any entries")

        // Verify files were extracted
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("dir/file.txt").path))
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("dir/subdir/file2.txt").path))

        // Verify content
        let content1 = try String(contentsOf: extractDir.appendingPathComponent("dir/file.txt"), encoding: .utf8)
        #expect(content1 == "test content")

        let content2 = try String(contentsOf: extractDir.appendingPathComponent("dir/subdir/file2.txt"), encoding: .utf8)
        #expect(content2 == "more content")
    }

    @Test func extractRootLevelFile() throws {
        let archiveURL = try createTestArchive(
            name: "root-level",
            entries: [
                ("file.txt", .regular("root file"), nil)
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "root-level")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("file.txt").path))

        let content = try String(contentsOf: extractDir.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(content == "root file")
    }

    // MARK: - Absolute Path Tests

    @Test func convertAbsolutePathToRelative() throws {
        let filename1: String = "/tmp/\(UUID())"
        let filename2: String = "//tmp//\(UUID())"
        let archiveURL = try createTestArchive(
            name: "benign-absolute",
            entries: [
                ("/tmp/\(filename1)", .regular("hello"), nil),
                ("//tmp//\(filename2)", .regular("world"), nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "benign-absolute")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Absolute paths should be rejected
        #expect(
            rejectedPaths.isEmpty,
            "Expected absolute paths allowed, but got rejected paths \(rejectedPaths)")

        // Verify nothing was extracted to /tmp or /etc
        #expect(!FileManager.default.fileExists(atPath: filename1))
        #expect(!FileManager.default.fileExists(atPath: filename2))
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("tmp/\(filename1)").path))
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("tmp/\(filename2)").path))
    }

    // MARK: - Path Traversal Attack Tests

    @Test func rejectPathTraversal() throws {
        let archiveURL = try createTestArchive(
            name: "evil-traversal",
            entries: [
                ("../etc/pwned", .regular("evil"), nil),
                ("foo/../../etc/pwned", .regular("evil"), nil),
                ("dir/../../../etc/pwned", .regular("evil"), nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "evil-traversal")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Path traversal entries should be rejected
        #expect(
            Set(rejectedPaths) == Set(["../etc/pwned", "foo/../../etc/pwned", "dir/../../../etc/pwned"]),
            "Expected path traversal entries to be rejected, got \(rejectedPaths)")

        // Verify nothing escaped
        let parentDir = extractDir.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: parentDir.appendingPathComponent("etc/pwned").path))
    }

    @Test func rejectPathTraversalWithValidEntries() throws {
        let archiveURL = try createTestArchive(
            name: "mixed-traversal",
            entries: [
                ("safe.txt", .regular("safe content"), nil),
                ("dir/", .directory, nil),
                ("dir/file.txt", .regular("also safe"), nil),
                ("../etc/pwned", .regular("evil"), nil),
                ("more/safe.txt", .regular("still safe"), nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "mixed-traversal")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Only the path traversal entry should be rejected
        #expect(
            rejectedPaths == ["../etc/pwned"],
            "Expected only path traversal entry to be rejected, got \(rejectedPaths)")

        // Valid entries should have been extracted
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("safe.txt").path))
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("dir/file.txt").path))
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("more/safe.txt").path))

        // Verify nothing escaped
        let parentDir = extractDir.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: parentDir.appendingPathComponent("etc/pwned").path))
    }

    @Test func rejectDotDotInMiddle() throws {
        let archiveURL = try createTestArchive(
            name: "evil-dotdot-middle",
            entries: [
                ("safe/../pwned.txt", .regular("evil"), nil)
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "evil-dotdot-middle")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths == ["safe/../pwned.txt"])
        #expect(!FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("pwned.txt").path))
    }

    // MARK: - Symlink Attack Tests

    @Test func allowValidSymlink() throws {
        let archiveURL = try createTestArchive(
            name: "safe-symlink",
            entries: [
                ("dir/", .directory, nil),
                ("dir/target.txt", .regular("target content"), nil),
                ("dir/link", .symlink, "target.txt"),
                ("link2", .symlink, "dir/target.txt"),
                ("dir/passwd", .symlink, "/etc/passwd"),
                ("dir2/passwd", .symlink, "../../../../etc/passwd"),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "safe-symlink")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty, "Valid symlinks should be allowed")

        // Verify symlinks were created
        let linkPath = extractDir.appendingPathComponent("dir/link").path
        #expect(FileManager.default.fileExists(atPath: linkPath))

        let link2Path = extractDir.appendingPathComponent("link2").path
        #expect(FileManager.default.fileExists(atPath: link2Path))

        // Verify symlinks point to correct targets
        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(linkTarget == "target.txt")

        let link2Target = try FileManager.default.destinationOfSymbolicLink(atPath: link2Path)
        #expect(link2Target == "dir/target.txt")
    }

    @Test func allowSymlinkWithDotDot() throws {
        let archiveURL = try createTestArchive(
            name: "safe-symlink-dotdot",
            entries: [
                ("dir/", .directory, nil),
                ("dir/subdir/", .directory, nil),
                ("target.txt", .regular("target"), nil),
                ("dir/subdir/link", .symlink, "../../target.txt"),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "safe-symlink-dotdot")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty, "Symlink with .. that stays in root should be allowed")

        let linkPath = extractDir.appendingPathComponent("dir/subdir/link").path
        #expect(FileManager.default.fileExists(atPath: linkPath))

        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(linkTarget == "../../target.txt")
    }

    // MARK: - Deep Nesting Tests

    @Test func extractDeepNesting() throws {
        var entries: [(String, EntryType, String?)] = []

        // Create 50 levels deep
        var path = ""
        for i in 0..<50 {
            if i > 0 { path += "/" }
            path += "level\(i)"
            entries.append((path + "/", .directory, nil))
        }
        entries.append((path + "/deep.txt", .regular("deep file"), nil))

        let archiveURL = try createTestArchive(name: "deep-nesting", entries: entries)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "deep-nesting")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty)

        // Verify deep file exists
        let deepFilePath = extractDir.appendingPathComponent(path + "/deep.txt").path
        #expect(FileManager.default.fileExists(atPath: deepFilePath))

        let content = try String(contentsOfFile: deepFilePath, encoding: .utf8)
        #expect(content == "deep file")
    }

    // MARK: - Normalization Tests

    @Test func handleDotSlashPrefix() throws {
        let archiveURL = try createTestArchive(
            name: "dot-slash",
            entries: [
                ("./safe.txt", .regular("content"), nil),
                ("./dir/", .directory, nil),
                ("./dir/file.txt", .regular("more content"), nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "dot-slash")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty, "./ prefix should be normalized and allowed")
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("safe.txt").path))
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("dir/file.txt").path))
    }

    @Test func handleDoubleSlashes() throws {
        let archiveURL = try createTestArchive(
            name: "double-slash",
            entries: [
                ("dir//subdir/", .directory, nil),
                ("dir//subdir//file.txt", .regular("content"), nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "double-slash")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty, "Double slashes should be normalized")

        // Verify file exists at normalized path
        let normalizedPath = "dir/subdir/file.txt"
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent(normalizedPath).path))
    }

    // MARK: - File Permissions Tests

    @Test func preserveFilePermissions() throws {
        let archiveURL = try createTestArchive(
            name: "permissions",
            entries: [
                ("executable.sh", .regular("#!/bin/bash\necho test"), nil)
            ])

        // Manually set executable permissions
        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        for (entry, _) in reader {
            if entry.path == "executable.sh" {
                entry.permissions = 0o755
            }
        }

        // Re-create archive with proper permissions
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveReaderTests")!
        let archiveURL2 = testDirectory.appendingPathComponent("permissions2.tar")
        let archiver = try ArchiveWriter(format: .paxRestricted, filter: .none, file: archiveURL2)

        let writeEntry = WriteEntry()
        writeEntry.path = "executable.sh"
        writeEntry.fileType = .regular
        writeEntry.permissions = 0o755
        let data = "#!/bin/bash\necho test".data(using: .utf8)!
        writeEntry.size = numericCast(data.count)
        try archiver.writeEntry(entry: writeEntry, data: data)
        try archiver.finishEncoding()

        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let extractDir = try createExtractionDirectory(name: "permissions")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader2 = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL2)
        let rejectedPaths = try reader2.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty)

        // Verify permissions were preserved
        let filePath = extractDir.appendingPathComponent("executable.sh").path
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let permMask: UInt16 = 0o777
        #expect((perms & permMask) == 0o755, "Permissions should be preserved")
    }

    // MARK: - Duplicate Entry Tests

    @Test func duplicateRegularFiles() throws {
        let archiveURL = try createTestArchive(
            name: "duplicate-regular",
            entries: [
                ("file.txt", .regular("first content"), nil),
                ("file.txt", .regular("second content"), nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "duplicate-regular")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Last entry wins - second file should replace first
        #expect(rejectedPaths.isEmpty, "Duplicate files follow last-entry-wins")

        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("file.txt").path))
        let content = try String(contentsOf: extractDir.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(content == "second content", "Last entry should win")
    }

    @Test func duplicateDirectories() throws {
        let archiveURL = try createTestArchive(
            name: "duplicate-dirs",
            entries: [
                ("dir/", .directory, nil),
                ("dir/", .directory, nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "duplicate-dirs")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Both directories should be accepted (merged)
        #expect(rejectedPaths.isEmpty, "Duplicate directories should be merged")
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("dir").path))
    }

    @Test func regularFileToDirectory() throws {
        let archiveURL = try createTestArchive(
            name: "file-to-dir",
            entries: [
                ("path", .regular("content"), nil),
                ("path/", .directory, nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "file-to-dir")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Directory should replace the file
        #expect(rejectedPaths.isEmpty, "Directory should replace regular file")

        let attrs = try FileManager.default.attributesOfItem(atPath: extractDir.appendingPathComponent("path").path)
        let fileType = attrs[.type] as? FileAttributeType
        #expect(fileType == .typeDirectory, "Path should be a directory")
    }

    @Test func directoryToRegularFile() throws {
        let archiveURL = try createTestArchive(
            name: "dir-to-file",
            entries: [
                ("path/", .directory, nil),
                ("path", .regular("content"), nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "dir-to-file")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Last entry wins - file should replace directory
        #expect(rejectedPaths.isEmpty, "Regular file should replace directory")

        // Should now be a regular file
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("path").path))
        let content = try String(contentsOf: extractDir.appendingPathComponent("path"), encoding: .utf8)
        #expect(content == "content", "Should have file content")
    }

    @Test func regularFileToSymlink() throws {
        let archiveURL = try createTestArchive(
            name: "file-to-symlink",
            entries: [
                ("target.txt", .regular("target"), nil),
                ("path", .regular("content"), nil),
                ("path", .symlink, "target.txt"),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "file-to-symlink")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Last entry wins - symlink should replace file
        #expect(rejectedPaths.isEmpty, "Symlink should replace regular file")

        // Should now be a symlink
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("path").path))
        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: extractDir.appendingPathComponent("path").path)
        #expect(linkTarget == "target.txt")
    }

    @Test func symlinkToRegularFile() throws {
        let archiveURL = try createTestArchive(
            name: "symlink-to-file",
            entries: [
                ("target.txt", .regular("target"), nil),
                ("path", .symlink, "target.txt"),
                ("path", .regular("new content"), nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "symlink-to-file")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Last entry wins - file should replace symlink
        #expect(rejectedPaths.isEmpty, "Regular file should replace symlink")

        // Should now be a regular file
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("path").path))
        let content = try String(contentsOf: extractDir.appendingPathComponent("path"), encoding: .utf8)
        #expect(content == "new content")
    }

    @Test func symlinkToDirectory() throws {
        let archiveURL = try createTestArchive(
            name: "symlink-to-dir",
            entries: [
                ("target/", .directory, nil),
                ("path", .symlink, "target"),
                ("path/", .directory, nil),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "symlink-to-dir")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Directory should replace symlink
        #expect(rejectedPaths.isEmpty, "Directory should replace symlink")

        // Path should now be a directory
        let attrs = try FileManager.default.attributesOfItem(atPath: extractDir.appendingPathComponent("path").path)
        let fileType = attrs[.type] as? FileAttributeType
        #expect(fileType == .typeDirectory, "Path should be a directory")
    }

    @Test func duplicateSymlinks() throws {
        let archiveURL = try createTestArchive(
            name: "duplicate-symlinks",
            entries: [
                ("target1.txt", .regular("target1"), nil),
                ("target2.txt", .regular("target2"), nil),
                ("link", .symlink, "target1.txt"),
                ("link", .symlink, "target2.txt"),
            ])

        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let extractDir = try createExtractionDirectory(name: "duplicate-symlinks")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        // Last entry wins - second symlink should replace first
        #expect(rejectedPaths.isEmpty, "Second symlink should replace first")

        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: extractDir.appendingPathComponent("link").path)
        #expect(linkTarget == "target2.txt", "Last symlink should win")
    }

    // MARK: - Empty Archive Tests

    @Test func rejectEmptyArchive() throws {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveReaderTests")!
        let archiveURL = testDirectory.appendingPathComponent("empty.tar")

        let archiver = try ArchiveWriter(format: .paxRestricted, filter: .none, file: archiveURL)
        try archiver.finishEncoding()

        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let extractDir = try createExtractionDirectory(name: "empty")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: archiveURL)

        #expect(throws: ArchiveError.self) {
            _ = try reader.extractContents(to: extractDir)
        }
    }

    // MARK: - Zstd Compression Tests

    @Test func readZstdCompressedArchive() throws {
        guard let resourceURL = Bundle.module.url(forResource: "test", withExtension: "tar.zst") else {
            Issue.record("Test resource test.tar.zst not found")
            return
        }

        let extractDir = try createExtractionDirectory(name: "zstd-test")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        // Test with explicit filter
        let reader = try ArchiveReader(format: .paxRestricted, filter: .zstd, file: resourceURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty, "No paths should be rejected")

        // Check extracted files
        let testFile = extractDir.appendingPathComponent("test.txt")
        let file2 = extractDir.appendingPathComponent("file2.txt")

        #expect(FileManager.default.fileExists(atPath: testFile.path), "test.txt should exist")
        #expect(FileManager.default.fileExists(atPath: file2.path), "file2.txt should exist")

        let testContent = try String(contentsOf: testFile, encoding: .utf8)
        #expect(testContent == "Hello from zstd compressed archive", "Content should match")

        let file2Content = try String(contentsOf: file2, encoding: .utf8)
        #expect(file2Content == "Another file", "Content should match")
    }

    @Test func readZstdCompressedArchiveAutoDetect() throws {
        guard let resourceURL = Bundle.module.url(forResource: "test", withExtension: "tar.zst") else {
            Issue.record("Test resource test.tar.zst not found")
            return
        }

        let extractDir = try createExtractionDirectory(name: "zstd-auto-test")
        defer { try? FileManager.default.removeItem(at: extractDir.deletingLastPathComponent()) }

        // Test with auto-detect
        let reader = try ArchiveReader(file: resourceURL)
        let rejectedPaths = try reader.extractContents(to: extractDir)

        #expect(rejectedPaths.isEmpty, "No paths should be rejected")

        // Check extracted files
        let testFile = extractDir.appendingPathComponent("test.txt")
        #expect(FileManager.default.fileExists(atPath: testFile.path), "test.txt should exist")

        let testContent = try String(contentsOf: testFile, encoding: .utf8)
        #expect(testContent == "Hello from zstd compressed archive", "Content should match")
    }
}
