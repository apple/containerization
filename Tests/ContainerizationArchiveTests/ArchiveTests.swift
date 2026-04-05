//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

//

import Foundation
import Testing

@testable import ContainerizationArchive

struct ArchiveTests {
    func helperEntry(path: String, data: Data) -> WriteEntry {
        let entry = WriteEntry()
        entry.permissions = 0o644
        entry.fileType = .regular
        entry.path = path
        entry.size = numericCast(data.count)
        entry.owner = 1
        entry.group = 2
        entry.xattrs = ["user.data": Data([1, 2, 3])]
        return entry
    }

    func archiveSourceEntry(pathOnHost: URL, pathInArchive: String) -> ArchiveSourceEntry {
        ArchiveSourceEntry(pathOnHost: pathOnHost, pathInArchive: pathInArchive)
    }

    @Test func createTemporaryDirectorySuccess() throws {
        // Test that createTemporaryDirectory creates a directory with randomized suffix
        let baseName = "ArchiveTests.testTempDir"
        guard let tempDir = createTemporaryDirectory(baseName: baseName) else {
            Issue.record("createTemporaryDirectory returned nil")
            return
        }

        defer {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: tempDir)
        }

        // Verify the directory exists
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: tempDir.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)

        // Verify the directory name starts with the base name
        let lastComponent = tempDir.lastPathComponent
        #expect(lastComponent.starts(with: baseName))

        // Verify that mkdtemp replaced the X's with random characters
        // (should be 6 random alphanumeric characters after the base name and dot)
        let suffix = String(lastComponent.dropFirst(baseName.count + 1))  // +1 for the dot
        #expect(suffix.count == 6, "Expected 6 character suffix, got \(suffix.count)")
        #expect(suffix != "XXXXXX", "mkdtemp did not replace X's with random characters")

        // Verify we can write to the directory
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(toFile: testFile.path, atomically: true, encoding: .utf8)
        #expect(fileManager.fileExists(atPath: testFile.path))
    }

    @Test func tarUTF8() throws {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveTests.testTarUTF8")!
        let archiveURL = testDirectory.appendingPathComponent("test.tgz")

        defer {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: testDirectory)
        }

        // this test would failed with ArchiveWriterConfiguration.locale was not set to "en_US.UTF-8"
        let archiver = try ArchiveWriter(format: .paxRestricted, filter: .gzip, file: archiveURL)

        let data = "blablabla".data(using: .utf8)!

        let normalPathEntry = helperEntry(path: "r", data: data)
        #expect(throws: Never.self) {
            try archiver.writeEntry(entry: normalPathEntry, data: data)
        }

        let weirdPathEntry = helperEntry(path: "ʀ", data: data)
        #expect(throws: Never.self) {
            try archiver.writeEntry(entry: weirdPathEntry, data: data)
        }
    }

    @Test func tarGzipWithOpenfile() throws {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveTests.testTarGzipWithOpenfile")!
        let archiveURL = testDirectory.appendingPathComponent("test.tgz")

        defer {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: testDirectory)
        }

        let configuration = ArchiveWriterConfiguration(
            format: .paxRestricted,
            filter: .gzip
        )
        let archiver = try ArchiveWriter(configuration: configuration)
        try archiver.open(file: archiveURL)

        let data = "foo".data(using: .utf8)!

        let normalPathEntry = helperEntry(path: "bar", data: data)
        #expect(throws: Never.self) {
            try archiver.writeEntry(entry: normalPathEntry, data: data)
        }

        try archiver.finishEncoding()
    }

    @Test func writingZip() throws {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveTests.testWritingZip")!
        let archiveURL = testDirectory.appendingPathComponent("test.zip")

        defer {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: testDirectory)
        }

        // When
        let archiver = try ArchiveWriter(format: .zip, filter: .none, file: archiveURL)

        var data = "foo".data(using: .utf8)!
        var entry = helperEntry(path: "foo.txt", data: data)
        try archiver.writeEntry(entry: entry, data: data)

        data = "bar".data(using: .utf8)!
        entry = helperEntry(path: "bar.txt", data: data)
        try archiver.writeEntry(entry: entry, data: data)

        data = Data()
        entry = helperEntry(path: "empty", data: data)
        try archiver.writeEntry(entry: entry, data: data)

        try archiver.finishEncoding()

        // Then
        let unarchiver = try ArchiveReader(format: .zip, filter: .none, file: archiveURL)
        for (index, (entry, data)) in unarchiver.enumerated() {
            #expect(entry.owner == 1)
            #expect(entry.group == 2)
            switch index {
            case 0:
                #expect(entry.path == "foo.txt")
                #expect(String(data: data, encoding: .utf8) == "foo")
            case 1:
                #expect(entry.path == "bar.txt")
                #expect(String(data: data, encoding: .utf8) == "bar")
            case 2:
                #expect(entry.path == "empty")
                #expect(data.isEmpty)
            default:
                Issue.record()
            }
        }
    }

    @Test func unarchiving_0bytesEntry() throws {
        let data = Data(base64Encoded: surveyBundleBase64Encoded)!
        let unarchiver = try ArchiveReader(name: "survey.zip", bundle: data)
        for (index, (entry, data)) in unarchiver.enumerated() {
            switch index {
            case 0:
                #expect(entry.path == "healthinvolvement.js")
                #expect(!data.isEmpty)
            case 1:
                #expect(entry.path == "__MACOSX/")
                #expect(data.isEmpty)
            case 2:
                #expect(entry.path == "__MACOSX/._healthinvolvement.js")
                #expect(!data.isEmpty)
            default:
                Issue.record()
            }
        }
    }

    @Test func writingReadingTar() throws {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveTests.testWritingReadingTar")!
        let archiveURL = testDirectory.appendingPathComponent("test.tar.gz")
        defer {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: testDirectory)
        }

        let archiver = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        let data = "foo".data(using: .utf8)!
        let entry = helperEntry(path: "foo.txt", data: data)
        try archiver.writeEntry(entry: entry, data: data)
        try archiver.finishEncoding()

        let unarchiver = try ArchiveReader(format: .pax, filter: .gzip, file: archiveURL)
        for (entry, _) in unarchiver {
            let attrs = entry.xattrs
            guard let val = attrs["user.data"] else {
                Issue.record("missing extended attribute [user.data] in file")
                return
            }
            #expect([UInt8](val) == [1, 2, 3])
        }
    }

    // MARK: - archiveDirectory round-trip tests

    @Test func archiveDirectoryBasic() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirBasic")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "hello".write(to: sourceDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)

        let subDir = sourceDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "world".write(to: subDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        #expect(try String(contentsOf: extractDir.appendingPathComponent("file1.txt"), encoding: .utf8) == "hello")
        #expect(try String(contentsOf: extractDir.appendingPathComponent("subdir/file2.txt"), encoding: .utf8) == "world")
    }

    @Test func archiveDirectoryEmpty() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirEmpty")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        // Empty directory archive should succeed with the leading "./" entry.
        let rejected = try reader.extractContents(to: extractDir)
        #expect(rejected.isEmpty)
        #expect(FileManager.default.fileExists(atPath: extractDir.path))
    }

    @Test func archiveDirectoryNestedEmpty() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirNestedEmpty")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sourceDir.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sourceDir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try "data".write(to: sourceDir.appendingPathComponent("a/file.txt"), atomically: true, encoding: .utf8)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        #expect(try String(contentsOf: extractDir.appendingPathComponent("a/file.txt"), encoding: .utf8) == "data")

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("a/b/c").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("empty").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func archiveDirectoryDeepNesting() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirDeep")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        var deepPath = sourceDir
        for i in 0..<20 {
            deepPath = deepPath.appendingPathComponent("level\(i)")
        }
        try FileManager.default.createDirectory(at: deepPath, withIntermediateDirectories: true)
        try "deep content".write(to: deepPath.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)

        var expectedPath = extractDir
        for i in 0..<20 {
            expectedPath = expectedPath.appendingPathComponent("level\(i)")
        }
        #expect(try String(contentsOf: expectedPath.appendingPathComponent("deep.txt"), encoding: .utf8) == "deep content")
    }

    @Test func archiveDirectorySymlinkInside() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirSymlinkInside")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "target content".write(to: sourceDir.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: sourceDir.appendingPathComponent("link.txt").path,
            withDestinationPath: "target.txt"
        )

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        #expect(try String(contentsOf: extractDir.appendingPathComponent("target.txt"), encoding: .utf8) == "target content")

        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: extractDir.appendingPathComponent("link.txt").path)
        #expect(linkDest == "target.txt")
    }

    @Test func archiveDirectoryPreservesInternalAbsoluteSymlink() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirAbsoluteSymlink")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let targetURL = sourceDir.appendingPathComponent("target.txt")
        try "target content".write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: sourceDir.appendingPathComponent("link.txt").path,
            withDestinationPath: targetURL.path
        )

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        let extractedLink = extractDir.appendingPathComponent("link.txt")
        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: extractedLink.path)
        #expect(linkDest == targetURL.path)
        #expect(try String(contentsOf: extractedLink, encoding: .utf8) == "target content")
    }

    @Test func archiveDirectorySymlinkOutsideExcluded() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirSymlinkOutside")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "inside".write(to: sourceDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Create a file outside the source directory
        try "outside".write(to: testDir.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)

        // Symlink pointing outside the source directory
        try FileManager.default.createSymbolicLink(
            atPath: sourceDir.appendingPathComponent("escape.txt").path,
            withDestinationPath: "../outside.txt"
        )

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        // Verify the archive doesn't contain the escaping symlink
        let reader = try ArchiveReader(file: archiveURL)
        var paths: [String] = []
        for (entry, _) in reader {
            if let path = entry.path {
                paths.append(path)
            }
        }
        #expect(!paths.contains("escape.txt"), "Symlink pointing outside should be excluded from archive")
        #expect(paths.contains("file.txt"), "Regular file should be included")
    }

    @Test func archiveDirectorySpecialCharacters() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirSpecialChars")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "spaces".write(to: sourceDir.appendingPathComponent("file with spaces.txt"), atomically: true, encoding: .utf8)
        try "unicode".write(to: sourceDir.appendingPathComponent("日本語.txt"), atomically: true, encoding: .utf8)
        try "dashes".write(to: sourceDir.appendingPathComponent("file-name_v2.0.txt"), atomically: true, encoding: .utf8)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        #expect(try String(contentsOf: extractDir.appendingPathComponent("file with spaces.txt"), encoding: .utf8) == "spaces")
        #expect(try String(contentsOf: extractDir.appendingPathComponent("日本語.txt"), encoding: .utf8) == "unicode")
        #expect(try String(contentsOf: extractDir.appendingPathComponent("file-name_v2.0.txt"), encoding: .utf8) == "dashes")
    }

    @Test func archiveDirectoryDotfiles() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirDotfiles")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "hidden".write(to: sourceDir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try "gitignore".write(to: sourceDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "visible".write(to: sourceDir.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)

        let hiddenDir = sourceDir.appendingPathComponent(".config")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try "config".write(to: hiddenDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        #expect(try String(contentsOf: extractDir.appendingPathComponent(".hidden"), encoding: .utf8) == "hidden")
        #expect(try String(contentsOf: extractDir.appendingPathComponent(".gitignore"), encoding: .utf8) == "gitignore")
        #expect(try String(contentsOf: extractDir.appendingPathComponent("visible.txt"), encoding: .utf8) == "visible")
        #expect(try String(contentsOf: extractDir.appendingPathComponent(".config/settings.json"), encoding: .utf8) == "config")
    }

    @Test func archiveDirectoryPreservesPermissions() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirPerms")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let execFile = sourceDir.appendingPathComponent("script.sh")
        try "#!/bin/sh\necho hi".write(to: execFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execFile.path)

        let readOnly = sourceDir.appendingPathComponent("readonly.txt")
        try "secret".write(to: readOnly, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)

        let execAttrs = try FileManager.default.attributesOfItem(atPath: extractDir.appendingPathComponent("script.sh").path)
        let execPerms = (execAttrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect((execPerms & 0o777) == 0o755, "Executable permissions should be preserved")

        let roAttrs = try FileManager.default.attributesOfItem(atPath: extractDir.appendingPathComponent("readonly.txt").path)
        let roPerms = (roAttrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect((roPerms & 0o777) == 0o444, "Read-only permissions should be preserved")
    }

    @Test func archiveDirectoryLargeFile() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirLargeFile")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        // 2MB file with repeating pattern
        let pattern = Data("ContainerizationArchiveTestPattern\n".utf8)
        var largeData = Data(capacity: 2 * 1024 * 1024)
        while largeData.count < 2 * 1024 * 1024 {
            largeData.append(pattern)
        }
        largeData = largeData.prefix(2 * 1024 * 1024)
        try largeData.write(to: sourceDir.appendingPathComponent("large.bin"))

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)

        let extracted = try Data(contentsOf: extractDir.appendingPathComponent("large.bin"))
        #expect(extracted == largeData, "Large file content should match after round-trip")
    }

    @Test func archiveDirectoryManyFiles() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirManyFiles")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        // Create 100 files
        for i in 0..<100 {
            try "content \(i)".write(
                to: sourceDir.appendingPathComponent("file_\(String(format: "%03d", i)).txt"),
                atomically: true, encoding: .utf8)
        }

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)

        for i in 0..<100 {
            let content = try String(
                contentsOf: extractDir.appendingPathComponent("file_\(String(format: "%03d", i)).txt"),
                encoding: .utf8)
            #expect(content == "content \(i)")
        }
    }

    @Test func archiveDirectorySingleFile() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirSingle")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "only file".write(to: sourceDir.appendingPathComponent("only.txt"), atomically: true, encoding: .utf8)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        #expect(try String(contentsOf: extractDir.appendingPathComponent("only.txt"), encoding: .utf8) == "only file")
    }

    @Test func archiveDirectorySymlinkRelativeSubdir() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveDirSymlinkRelSubdir")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        let subA = sourceDir.appendingPathComponent("a")
        let subB = sourceDir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        try "in a".write(to: subA.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Symlink from b/link.txt -> ../a/file.txt (relative, stays inside)
        try FileManager.default.createSymbolicLink(
            atPath: subB.appendingPathComponent("link.txt").path,
            withDestinationPath: "../a/file.txt"
        )

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveDirectory(sourceDir)
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)

        let linkDest = try FileManager.default.destinationOfSymbolicLink(
            atPath: extractDir.appendingPathComponent("b/link.txt").path)
        #expect(linkDest == "../a/file.txt")

        // Verify the symlink resolves correctly
        let content = try String(contentsOf: extractDir.appendingPathComponent("b/link.txt"), encoding: .utf8)
        #expect(content == "in a")
    }

    @Test func archiveEntriesPreservesInternalAbsoluteSymlink() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveEntriesInternalAbsolute")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let targetURL = sourceDir.appendingPathComponent("target.txt")
        try "hello".write(to: targetURL, atomically: true, encoding: .utf8)
        let linkURL = sourceDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: targetURL.path)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveEntries([
            archiveSourceEntry(pathOnHost: targetURL, pathInArchive: "target.txt"),
            archiveSourceEntry(pathOnHost: linkURL, pathInArchive: "link.txt"),
        ])
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        let extractedLink = extractDir.appendingPathComponent("link.txt")
        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: extractedLink.path)
        #expect(linkDest == targetURL.path)
        #expect(try String(contentsOf: extractedLink, encoding: .utf8) == "hello")
    }

    @Test func archiveEntriesPreservesExternalAbsoluteSymlink() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveEntriesExternalAbsolute")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let externalTargetURL = testDir.appendingPathComponent("external-target.txt")
        try "external".write(to: externalTargetURL, atomically: true, encoding: .utf8)
        let linkURL = sourceDir.appendingPathComponent("absolute-link.txt")
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: externalTargetURL.path)

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveEntries([
            archiveSourceEntry(pathOnHost: linkURL, pathInArchive: "absolute-link.txt")
        ])
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        let extractedLink = extractDir.appendingPathComponent("absolute-link.txt")
        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: extractedLink.path)
        #expect(linkDest == externalTargetURL.path)
    }

    @Test func archiveEntriesPreservesAbsoluteSymlinkThroughAncestorSymlink() throws {
        let testDir = createTemporaryDirectory(baseName: "ArchiveTests.archiveEntriesCanonicalAbsolute")!
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let realDirURL = sourceDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDirURL, withIntermediateDirectories: true)
        let targetURL = realDirURL.appendingPathComponent("target.txt")
        try "hello".write(to: targetURL, atomically: true, encoding: .utf8)

        let aliasURL = sourceDir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: aliasURL.path, withDestinationPath: "real")

        let linkURL = sourceDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: sourceDir.appendingPathComponent("alias/target.txt").path
        )

        let archiveURL = testDir.appendingPathComponent("test.tar.gz")
        let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        try writer.archiveEntries([
            archiveSourceEntry(pathOnHost: realDirURL, pathInArchive: "real"),
            archiveSourceEntry(pathOnHost: targetURL, pathInArchive: "real/target.txt"),
            archiveSourceEntry(pathOnHost: linkURL, pathInArchive: "link.txt"),
        ])
        try writer.finishEncoding()

        let extractDir = testDir.appendingPathComponent("extract")
        let reader = try ArchiveReader(file: archiveURL)
        let rejected = try reader.extractContents(to: extractDir)

        #expect(rejected.isEmpty)
        let extractedLink = extractDir.appendingPathComponent("link.txt")
        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: extractedLink.path)
        #expect(linkDest == sourceDir.appendingPathComponent("alias/target.txt").path)
        #expect(try String(contentsOf: extractedLink, encoding: .utf8) == "hello")
    }
}

private let surveyBundleBase64Encoded = """
    UEsDBBQACAAIAA17o04AAAAAAAAAAAAAAAAUABAAaGVhbHRoaW52b2x2ZW1lbnQuanNVWAwAQ8XMXJm/zFz1ARQAnVVRa9swEH73rzjylMLwmu3NJexhDLqxroPAYIxRFPsca5UlT5LteSH/fSdZdu02LqMiEEl3uvv06e5zwzRwyS1n4q4qmEHYwjECGn6VwKrSXGluu9Urv50rXSbBxWBquZImgR9+/Wgcz226IVTKBP+L2We2R0E5rlULrapFBp2qYY/GQoYm1XyPbsdBbJRosERpaQ7cmBoNaBTMYgZW9V4FMmGLdwBfBbqrpIVS9KckxgH9mXGPHSGYJFh2ZdK0qJPli9mucpTtuDwIfF8onuJytNTbl8ibj+NTzr4oC4x+QgzsZDHcdIGElGmESquGZ6gh45qeykDpyAgeI3s9mcQQNEzUhP8STougn4W0UyW2BbMTQB8h9e9KD5kpogVKRcDowUom2QGhHABP8m9emv8b6m6W29KacrVK3wMzwMAiK6HldPvyPFPPI3vzUmQf/lhNxSXm8FQrH9JQdWVA6JgEljUUwKJrNnIwKPIJiLf/BeLnksvyYW5uK9fPjBDnTBg853h6vNknOkWnKMpr6QUB0EGlC6yxoYa6CA3TkNYMGuMNsV9dRd7Kc1gH63brGtKL0upi0m0aba3lXK9C9mhiP47alVHrrxaw3Wk0FYkXmvU4G5KFQOP+LADVyoEsZn65cOR2/4s6LSZRCfb4IXgsUB7ooV/DxgV0dPymznNBJaMOHaWXKlFannOnNatUlTFLWxRCUtJ4diLuS+epeFluhSPgxtWya7vvTh+vvXdw6QXWP7hTYG/q4BP5SexgV+sGB81vUJvebRNfDt+BQEcyEtrvh5XSyRmme5eBwGScOTqi2c2uon9QSwcIxOijbWkCAACaBgAAUEsDBAoAAAAAAFV+o04AAAAAAAAAAAAAAAAJABAAX19NQUNPU1gvVVgMAMHFzFzBxcxc9QEUAFBLAwQUAAgACAANe6NOAAAAAAAAAAAAAAAAHwAQAF9fTUFDT1NYLy5faGVhbHRoaW52b2x2ZW1lbnQuanNVWAwAQ8XMXJm/zFz1ARQAjY/NSsNAEMcnRfHjVBA9eLGiHjy0m5qkDa2XtGlrwVKxAUUUWZMpiW4+mmzrxZtP4pOINw8efQXx6BMIbmigUBAd2P/MDr8/MwOLG0uQA+hRu9AfFM4LWaQ9WBHvAED6Eln8c9vwrzAs63RapQ5pVxTfc8hC1s8DbNqhX6JRxLDEaMLHCToO5bhzMpiikipEA9ifcT5yKhhau+uZXY6+Gd4HLKQOOqZwph5PyAPA3u+eMxdjbMehn6T8h5BDgPUZPxrTmAbcCxDen98u002cz9dymm8i5iVclp8kxXghV7j1eLO8mi0rZQfm5g5em5mu8z2X8yipERJhFGFsu5RnU8V8MvQYJqRMNLVK/LDV71iMWW583OyY5Agp4243mIRsgj4GvHSb/Dn7YkRkWVfqmk1RV3RaH9Ahjb16y6hUKxVNK8rtcqOo6kIastooNlXT1IyWoTYVA34AUEsHCAK+cV1ZAQAAIQIAAFBLAQIVAxQACAAIAA17o07E6KNtaQIAAJoGAAAUAAwAAAAAAAAAAECkgQAAAABoZWFsdGhpbnZvbHZlbWVudC5qc1VYCABDxcxcmb/MXFBLAQIVAwoAAAAAAFV+o04AAAAAAAAAAAAAAAAJAAwAAAAAAAAAAED9QbsCAABfX01BQ09TWC9VWAgAwcXMXMHFzFxQSwECFQMUAAgACAANe6NOAr5xXVkBAAAhAgAAHwAMAAAAAAAAAABApIHyAgAAX19NQUNPU1gvLl9oZWFsdGhpbnZvbHZlbWVudC5qc1VYCABDxcxcmb/MXFBLBQYAAAAAAwADAOoAAACoBAAAAAA=
    """
