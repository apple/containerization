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

@testable import _ContainerizationTar

#if canImport(_NIOFileSystem)
import NIOCore
import _NIOFileSystem
#endif

// MARK: - TarHeader Tests

@Suite("TarHeader Tests")
struct TarHeaderTests {

    // MARK: - Octal Encoding Tests

    @Test("Format octal - zero")
    func formatOctalZero() {
        let result = TarHeader.formatOctal(0, width: 8)
        // Should be "0000000\0"
        #expect(result.count == 8)
        #expect(result[0] == 0x30)  // '0'
        #expect(result[6] == 0x30)  // '0'
        #expect(result[7] == 0x00)  // null terminator
    }

    @Test("Format octal - small number")
    func formatOctalSmall() {
        let result = TarHeader.formatOctal(0o755, width: 8)
        let string = String(decoding: result.dropLast(), as: UTF8.self)
        #expect(string == "0000755")
    }

    @Test("Format octal - file size")
    func formatOctalFileSize() {
        let result = TarHeader.formatOctal(1234, width: 12)
        // 1234 in octal is 2322
        let string = String(decoding: result.dropLast(), as: UTF8.self)
        #expect(string.contains("2322"))
    }

    @Test("Format octal - max traditional size")
    func formatOctalMaxSize() {
        let maxSize: Int64 = 0o77777777777  // ~8GB
        let result = TarHeader.formatOctal(maxSize, width: 12)
        let string = String(decoding: result.dropLast(), as: UTF8.self)
        #expect(string == "77777777777")
    }

    // MARK: - Octal Parsing Tests

    @Test("Parse octal - zero")
    func parseOctalZero() {
        let bytes: [UInt8] = Array("0000000\0".utf8)
        let result = TarHeader.parseOctal(bytes[...])
        #expect(result == 0)
    }

    @Test("Parse octal - permissions")
    func parseOctalPermissions() {
        let bytes: [UInt8] = Array("0000755\0".utf8)
        let result = TarHeader.parseOctal(bytes[...])
        #expect(result == 0o755)
    }

    @Test("Parse octal - with spaces")
    func parseOctalWithSpaces() {
        let bytes: [UInt8] = Array("   755 \0".utf8)
        let result = TarHeader.parseOctal(bytes[...])
        #expect(result == 0o755)
    }

    @Test("Parse octal - file size")
    func parseOctalFileSize() {
        let bytes: [UInt8] = Array("00000002322\0".utf8)
        let result = TarHeader.parseOctal(bytes[...])
        #expect(result == 1234)
    }

    // MARK: - String Parsing Tests

    @Test("Parse string - null terminated")
    func parseStringNullTerminated() {
        var bytes: [UInt8] = Array("hello.txt".utf8)
        bytes.append(0)
        bytes.append(contentsOf: [0, 0, 0])  // Padding
        let result = TarHeader.parseString(bytes[...])
        #expect(result == "hello.txt")
    }

    @Test("Parse string - full field")
    func parseStringFullField() {
        let bytes: [UInt8] = Array("thisisaverylongfilename".utf8)
        let result = TarHeader.parseString(bytes[...])
        #expect(result == "thisisaverylongfilename")
    }

    // MARK: - Header Serialization Tests

    @Test("Serialize simple header")
    func serializeSimpleHeader() throws {
        let header = TarHeader(
            path: "hello.txt",
            mode: 0o644,
            uid: 1000,
            gid: 1000,
            size: 13,
            mtime: 1_704_067_200,  // 2024-01-01 00:00:00 UTC
            entryType: .regular,
            userName: "user",
            groupName: "group"
        )

        let serialized = try #require(header.serialize())
        #expect(serialized.count == 512)

        // Verify name field
        let name = TarHeader.parseString(serialized[0..<100])
        #expect(name == "hello.txt")

        // Verify magic
        let magic = Array(serialized[257..<263])
        #expect(magic == TarConstants.magic)

        // Verify version
        let version = Array(serialized[263..<265])
        #expect(version == TarConstants.version)
    }

    @Test("Serialize directory header")
    func serializeDirectoryHeader() throws {
        let header = TarHeader(
            path: "mydir/",
            mode: 0o755,
            entryType: .directory
        )

        let serialized = try #require(header.serialize())

        // Verify type flag
        #expect(serialized[156] == TarEntryType.directory.rawValue)

        // Verify name ends with /
        let name = TarHeader.parseString(serialized[0..<100])
        #expect(name.hasSuffix("/"))
    }

    @Test("Serialize returns nil for long path")
    func serializeLongPathReturnsNil() {
        // Path longer than 255 bytes (100 name + 155 prefix)
        let longPath = String(repeating: "a", count: 300)
        let header = TarHeader(path: longPath)

        let serialized = header.serialize()
        #expect(serialized == nil)
    }

    // MARK: - Header Parsing Tests

    @Test("Parse serialized header roundtrip")
    func parseSerializedHeaderRoundtrip() throws {
        let original = TarHeader(
            path: "test/file.txt",
            mode: 0o644,
            uid: 1000,
            gid: 1000,
            size: 12345,
            mtime: 1_704_067_200,
            entryType: .regular,
            userName: "testuser",
            groupName: "testgroup"
        )

        let serialized = try #require(original.serialize())
        let parsed = try #require(TarHeader.parse(from: serialized))

        #expect(parsed.path == original.path)
        #expect(parsed.mode == original.mode)
        #expect(parsed.uid == original.uid)
        #expect(parsed.gid == original.gid)
        #expect(parsed.size == original.size)
        #expect(parsed.mtime == original.mtime)
        #expect(parsed.entryType == original.entryType)
        #expect(parsed.userName == original.userName)
        #expect(parsed.groupName == original.groupName)
    }

    @Test("Parse empty block returns nil")
    func parseEmptyBlockReturnsNil() {
        let emptyBlock = [UInt8](repeating: 0, count: 512)
        let result = TarHeader.parse(from: emptyBlock)
        #expect(result == nil)
    }

    @Test("Parse corrupted header returns nil")
    func parseCorruptedHeaderReturnsNil() throws {
        let header = TarHeader(path: "test.txt", size: 100)
        var serialized = try #require(header.serialize())

        // Corrupt the checksum
        serialized[148] = 0xFF
        serialized[149] = 0xFF

        let result = TarHeader.parse(from: serialized)
        #expect(result == nil)
    }

    // MARK: - Entry Type Tests

    @Test("Entry type regular file detection")
    func entryTypeRegularFile() {
        #expect(TarEntryType.regular.isRegularFile)
        #expect(TarEntryType.regularAlt.isRegularFile)
        #expect(!TarEntryType.directory.isRegularFile)
        #expect(!TarEntryType.symbolicLink.isRegularFile)
    }
}

// MARK: - TarPax Tests

@Suite("TarPax Tests")
struct TarPaxTests {

    @Test("Make PAX record - short value")
    func makePaxRecordShort() {
        let record = TarPax.makeRecord(key: "path", value: "test.txt")
        let string = String(decoding: record, as: UTF8.self)

        // Format: "LENGTH path=test.txt\n"
        #expect(string.hasSuffix("\n"))
        #expect(string.contains("path=test.txt"))

        // Verify length is correct
        let parts = string.split(separator: " ", maxSplits: 1)
        let declaredLength = Int(parts[0])!
        #expect(declaredLength == record.count)
    }

    @Test("Make PAX record - long value")
    func makePaxRecordLong() {
        let longPath = String(repeating: "a", count: 200)
        let record = TarPax.makeRecord(key: "path", value: longPath)
        let string = String(decoding: record, as: UTF8.self)

        // Verify length is correct (length field will be 3 digits)
        let parts = string.split(separator: " ", maxSplits: 1)
        let declaredLength = Int(parts[0])!
        #expect(declaredLength == record.count)
    }

    @Test("Make PAX record - length crosses digit boundary")
    func makePaxRecordLengthCrossesBoundary() {
        // Create a value that causes the length to cross from 1 to 2 digits
        // "9 k=v\n" = 6 bytes, but if we add one more byte to value...
        let record = TarPax.makeRecord(key: "a", value: "bb")
        let string = String(decoding: record, as: UTF8.self)

        let parts = string.split(separator: " ", maxSplits: 1)
        let declaredLength = Int(parts[0])!
        #expect(declaredLength == record.count)
    }

    @Test("Parse PAX records - single record")
    func parsePaxRecordsSingle() {
        let record = TarPax.makeRecord(key: "path", value: "/long/path/to/file.txt")
        let parsed = TarPax.parseRecords(record)

        #expect(parsed["path"] == "/long/path/to/file.txt")
    }

    @Test("Parse PAX records - multiple records")
    func parsePaxRecordsMultiple() {
        var data: [UInt8] = []
        data.append(contentsOf: TarPax.makeRecord(key: "path", value: "/some/path"))
        data.append(contentsOf: TarPax.makeRecord(key: "size", value: "9999999999"))
        data.append(contentsOf: TarPax.makeRecord(key: "uid", value: "65534"))

        let parsed = TarPax.parseRecords(data)

        #expect(parsed["path"] == "/some/path")
        #expect(parsed["size"] == "9999999999")
        #expect(parsed["uid"] == "65534")
    }

    @Test("Requires PAX - short path")
    func requiresPaxShortPath() {
        let header = TarHeader(path: "short.txt", size: 100)
        #expect(!TarPax.requiresPax(header))
    }

    @Test("Requires PAX - long path")
    func requiresPaxLongPath() {
        let longPath = String(repeating: "a", count: 150)
        let header = TarHeader(path: longPath, size: 100)
        #expect(TarPax.requiresPax(header))
    }

    @Test("Requires PAX - large size")
    func requiresPaxLargeSize() {
        let header = TarHeader(path: "file.txt", size: 10_000_000_000)
        #expect(TarPax.requiresPax(header))
    }

    @Test("Requires PAX - large UID")
    func requiresPaxLargeUid() {
        let header = TarHeader(path: "file.txt", uid: 3_000_000)
        #expect(TarPax.requiresPax(header))
    }

    @Test("Apply overrides")
    func applyOverrides() {
        var header = TarHeader(
            path: "truncated.txt",
            uid: 0,
            size: 100
        )

        let overrides = [
            "path": "/very/long/path/to/file.txt",
            "size": "999999999999",
            "uid": "65534",
        ]

        TarPax.applyOverrides(overrides, to: &header)

        #expect(header.path == "/very/long/path/to/file.txt")
        #expect(header.size == 999_999_999_999)
        #expect(header.uid == 65534)
    }
}

// MARK: - TarWriter/TarReader Roundtrip Tests

@Suite("Tar Roundtrip Tests")
struct TarRoundtripTests {

    /// Helper to create a temporary file path.
    func temporaryFilePath(name: String = "test.tar") -> FilePath {
        let tempDir = FileManager.default.temporaryDirectory.path
        let uuid = UUID().uuidString
        return FilePath("\(tempDir)/\(uuid)-\(name)")
    }

    /// Helper to clean up a temporary file.
    func cleanup(_ path: FilePath) {
        try? FileManager.default.removeItem(atPath: path.string)
    }

    @Test("Write and read single file")
    func writeAndReadSingleFile() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        let content = Array("Hello, World!".utf8)

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: "hello.txt", size: Int64(content.count), mode: 0o644)
            try content.withUnsafeBytes { ptr in
                try writer.writeContent(ptr)
            }
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        try #require(header.path == "hello.txt")
        try #require(header.size == Int64(content.count))
        try #require(header.mode == 0o644)
        try #require(header.entryType == .regular)

        // Read content
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1024, alignment: 1)
        defer { buffer.deallocate() }

        let bytesRead = try reader.readContent(into: buffer)
        try #require(bytesRead == content.count)

        let readContent = Array(UnsafeRawBufferPointer(buffer)[0..<bytesRead])
        try #require(readContent == content)

        // Should be end of archive
        let nextHeader = try reader.nextHeader()
        try #require(nextHeader == nil)
    }

    @Test("Write and read directory")
    func writeAndReadDirectory() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        do {
            let writer = try TarWriter(path: path)
            try writer.writeDirectory(path: "mydir", mode: 0o755)
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        #expect(header.path == "mydir/")
        #expect(header.entryType == .directory)
        #expect(header.mode == 0o755)
        #expect(header.size == 0)
    }

    @Test("Write and read symlink")
    func writeAndReadSymlink() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        do {
            let writer = try TarWriter(path: path)
            try writer.writeSymlink(path: "link", target: "target.txt")
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        #expect(header.path == "link")
        #expect(header.entryType == .symbolicLink)
        #expect(header.linkName == "target.txt")
    }

    @Test("Write and read multiple entries")
    func writeAndReadMultipleEntries() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        let file1Content = Array("File 1 content".utf8)
        let file2Content = Array("File 2 has more content here".utf8)

        do {
            let writer = try TarWriter(path: path)

            // Directory
            try writer.writeDirectory(path: "mydir", mode: 0o755)

            // File 1
            try writer.beginFile(path: "mydir/file1.txt", size: Int64(file1Content.count))
            try file1Content.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()

            // File 2
            try writer.beginFile(path: "mydir/file2.txt", size: Int64(file2Content.count))
            try file2Content.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()

            // Symlink
            try writer.writeSymlink(path: "mydir/link", target: "file1.txt")

            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1024, alignment: 1)
        defer { buffer.deallocate() }

        // Entry 1: Directory
        let h1 = try #require(try reader.nextHeader())
        #expect(h1.path == "mydir/")
        #expect(h1.entryType == .directory)

        // Entry 2: File 1
        let h2 = try #require(try reader.nextHeader())
        #expect(h2.path == "mydir/file1.txt")
        #expect(h2.entryType == .regular)
        let bytes2 = try reader.readContent(into: buffer)
        #expect(bytes2 == file1Content.count)
        #expect(Array(UnsafeRawBufferPointer(buffer)[0..<bytes2]) == file1Content)

        // Entry 3: File 2
        let h3 = try #require(try reader.nextHeader())
        #expect(h3.path == "mydir/file2.txt")
        let bytes3 = try reader.readContent(into: buffer)
        #expect(bytes3 == file2Content.count)

        // Entry 4: Symlink
        let h4 = try #require(try reader.nextHeader())
        #expect(h4.path == "mydir/link")
        #expect(h4.entryType == .symbolicLink)
        #expect(h4.linkName == "file1.txt")

        // End of archive
        #expect(try reader.nextHeader() == nil)
    }

    @Test("Write and read empty file")
    func writeAndReadEmptyFile() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: "empty.txt", size: 0)
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        #expect(header.path == "empty.txt")
        #expect(header.size == 0)
        #expect(reader.contentBytesRemaining == 0)
    }

    @Test("Write and read with chunked content")
    func writeAndReadChunkedContent() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        // Create content larger than typical chunk size
        let totalSize = 100_000
        var content = [UInt8](repeating: 0, count: totalSize)
        for i in 0..<totalSize {
            content[i] = UInt8(i % 256)
        }

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: "large.bin", size: Int64(totalSize))

            let chunkSize = 16384
            var offset = 0
            while offset < totalSize {
                let end = min(offset + chunkSize, totalSize)
                try content[offset..<end].withUnsafeBytes { ptr in
                    try writer.writeContent(ptr)
                }
                offset = end
            }

            try writer.finalizeEntry()
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())
        #expect(header.size == Int64(totalSize))

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 8192, alignment: 1)
        defer { buffer.deallocate() }

        var readContent = [UInt8]()
        while reader.contentBytesRemaining > 0 {
            let bytesRead = try reader.readContent(into: buffer)
            readContent.append(contentsOf: UnsafeRawBufferPointer(buffer)[0..<bytesRead])
        }

        #expect(readContent == content)
    }

    @Test("Skip remaining content")
    func skipRemainingContent() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        let content1 = Array("First file content".utf8)
        let content2 = Array("Second file".utf8)

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: "file1.txt", size: Int64(content1.count))
            try content1.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()

            try writer.beginFile(path: "file2.txt", size: Int64(content2.count))
            try content2.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()

            try writer.finalize()
        }

        let reader = try TarReader(path: path)

        let h1 = try #require(try reader.nextHeader())
        #expect(h1.path == "file1.txt")
        // Don't read content, just skip
        try reader.skipRemainingContent()

        let h2 = try #require(try reader.nextHeader())
        #expect(h2.path == "file2.txt")

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1024, alignment: 1)
        defer { buffer.deallocate() }
        let bytesRead = try reader.readContent(into: buffer)
        #expect(bytesRead == content2.count)
    }

    @Test("Write file from file descriptor")
    func writeFileFromFileDescriptor() throws {
        let tarPath = temporaryFilePath()
        defer { cleanup(tarPath) }

        let sourceDir = FileManager.default.temporaryDirectory.path
        let sourceFile = "\(sourceDir)/\(UUID().uuidString)-source.txt"
        defer { try? FileManager.default.removeItem(atPath: sourceFile) }

        let content = "Hello from the source file!\nThis has multiple lines.\n"
        try content.write(toFile: sourceFile, atomically: true, encoding: .utf8)

        do {
            let writer = try TarWriter(path: tarPath)
            let sourceFd = try FileDescriptor.open(FilePath(sourceFile), .readOnly)
            defer { try? sourceFd.close() }

            try writer.writeFile(path: "copied.txt", from: sourceFd, mode: 0o600)
            try writer.finalize()
        }

        let reader = try TarReader(path: tarPath)
        let header = try #require(try reader.nextHeader())

        #expect(header.path == "copied.txt")
        #expect(header.size == Int64(content.utf8.count))
        #expect(header.mode == 0o600)
        #expect(header.entryType == .regular)

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buffer.deallocate() }

        var readData = [UInt8]()
        while reader.contentBytesRemaining > 0 {
            let bytesRead = try reader.readContent(into: buffer)
            readData.append(contentsOf: UnsafeRawBufferPointer(buffer)[0..<bytesRead])
        }

        let readContent = String(decoding: readData, as: UTF8.self)
        #expect(readContent == content)

        #expect(try reader.nextHeader() == nil)
    }

    @Test("Read file to file descriptor")
    func readFileToFileDescriptor() throws {
        let tarPath = temporaryFilePath()
        defer { cleanup(tarPath) }

        let content = "This is the file content that will be extracted.\nMultiple lines here.\n"
        let contentBytes = Array(content.utf8)

        do {
            let writer = try TarWriter(path: tarPath)
            try writer.beginFile(path: "extract-me.txt", size: Int64(contentBytes.count), mode: 0o644)
            try contentBytes.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let destDir = FileManager.default.temporaryDirectory.path
        let destFile = "\(destDir)/\(UUID().uuidString)-extracted.txt"
        defer { try? FileManager.default.removeItem(atPath: destFile) }

        let reader = try TarReader(path: tarPath)
        let header = try #require(try reader.nextHeader())
        #expect(header.path == "extract-me.txt")

        let destFd = try FileDescriptor.open(
            FilePath(destFile),
            .writeOnly,
            options: [.create, .truncate],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        )
        defer { try? destFd.close() }

        try reader.readFile(to: destFd)

        let extractedContent = try String(contentsOfFile: destFile, encoding: .utf8)
        #expect(extractedContent == content)
        #expect(try reader.nextHeader() == nil)
    }

    @Test("Read file to file descriptor with large content")
    func readFileToFileDescriptorLarge() throws {
        let tarPath = temporaryFilePath()
        defer { cleanup(tarPath) }

        let totalSize = 500_000
        var content = [UInt8](repeating: 0, count: totalSize)
        for i in 0..<totalSize {
            content[i] = UInt8(i % 256)
        }

        do {
            let writer = try TarWriter(path: tarPath)
            try writer.beginFile(path: "large.bin", size: Int64(totalSize))
            try content.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let destDir = FileManager.default.temporaryDirectory.path
        let destFile = "\(destDir)/\(UUID().uuidString)-large.bin"
        defer { try? FileManager.default.removeItem(atPath: destFile) }

        let reader = try TarReader(path: tarPath)
        let header = try #require(try reader.nextHeader())
        #expect(header.size == Int64(totalSize))

        let destFd = try FileDescriptor.open(
            FilePath(destFile),
            .writeOnly,
            options: [.create, .truncate],
            permissions: [.ownerReadWrite]
        )
        defer { try? destFd.close() }

        try reader.readFile(to: destFd)

        let extractedData = try Data(contentsOf: URL(fileURLWithPath: destFile))
        #expect(extractedData.count == totalSize)
        #expect(Array(extractedData) == content)
    }
}

// MARK: - Async File I/O Tests

#if canImport(_NIOFileSystem)
@Suite("Async File I/O Tests")
struct AsyncFileIOTests {

    func temporaryFilePath(name: String = "test.tar") -> FilePath {
        let tempDir = FileManager.default.temporaryDirectory.path
        let uuid = UUID().uuidString
        return FilePath("\(tempDir)/\(uuid)-\(name)")
    }

    func cleanup(_ path: FilePath) {
        try? FileManager.default.removeItem(atPath: path.string)
    }

    @Test("Async write file from readable handle")
    func asyncWriteFileFromHandle() async throws {
        let tarPath = temporaryFilePath()
        defer { cleanup(tarPath) }

        let sourceDir = FileManager.default.temporaryDirectory.path
        let sourceFile = "\(sourceDir)/\(UUID().uuidString)-source.txt"
        defer { try? FileManager.default.removeItem(atPath: sourceFile) }

        let content = "Hello from async source file!\nMultiple lines here.\n"
        try content.write(toFile: sourceFile, atomically: true, encoding: .utf8)

        let writer = try TarWriter(path: tarPath)
        try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(sourceFile)) { handle in
            try await writer.writeFile(path: "async-copied.txt", from: handle, mode: 0o600)
        }
        try writer.finalize()

        let reader = try TarReader(path: tarPath)
        let header = try #require(try reader.nextHeader())

        #expect(header.path == "async-copied.txt")
        #expect(header.size == Int64(content.utf8.count))
        #expect(header.mode == 0o600)

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buffer.deallocate() }

        var readData = [UInt8]()
        while reader.contentBytesRemaining > 0 {
            let bytesRead = try reader.readContent(into: buffer)
            readData.append(contentsOf: UnsafeRawBufferPointer(buffer)[0..<bytesRead])
        }

        let readContent = String(decoding: readData, as: UTF8.self)
        #expect(readContent == content)
    }

    @Test("Async read file to writable handle")
    func asyncReadFileToHandle() async throws {
        let tarPath = temporaryFilePath()
        defer { cleanup(tarPath) }

        let content = "This content will be extracted asynchronously.\n"
        let contentBytes = Array(content.utf8)

        do {
            let writer = try TarWriter(path: tarPath)
            try writer.beginFile(path: "async-extract.txt", size: Int64(contentBytes.count), mode: 0o644)
            try contentBytes.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let destDir = FileManager.default.temporaryDirectory.path
        let destFile = "\(destDir)/\(UUID().uuidString)-async-extracted.txt"
        defer { try? FileManager.default.removeItem(atPath: destFile) }

        let reader = try TarReader(path: tarPath)
        let header = try #require(try reader.nextHeader())
        #expect(header.path == "async-extract.txt")

        try await FileSystem.shared.withFileHandle(
            forWritingAt: FilePath(destFile),
            options: .newFile(replaceExisting: false)
        ) { handle in
            try await reader.readFile(to: handle)
        }

        let extractedContent = try String(contentsOfFile: destFile, encoding: .utf8)
        #expect(extractedContent == content)
    }

    @Test("Async roundtrip with large file")
    func asyncRoundtripLargeFile() async throws {
        let tarPath = temporaryFilePath()
        defer { cleanup(tarPath) }

        let sourceDir = FileManager.default.temporaryDirectory.path
        let sourceFile = "\(sourceDir)/\(UUID().uuidString)-large-source.bin"
        defer { try? FileManager.default.removeItem(atPath: sourceFile) }

        let totalSize = 500_000
        var content = [UInt8](repeating: 0, count: totalSize)
        for i in 0..<totalSize {
            content[i] = UInt8(i % 256)
        }
        try Data(content).write(to: URL(fileURLWithPath: sourceFile))

        let writer = try TarWriter(path: tarPath)
        try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(sourceFile)) { handle in
            try await writer.writeFile(path: "large-async.bin", from: handle)
        }
        try writer.finalize()

        let destFile = "\(sourceDir)/\(UUID().uuidString)-large-dest.bin"
        defer { try? FileManager.default.removeItem(atPath: destFile) }

        let reader = try TarReader(path: tarPath)
        let header = try #require(try reader.nextHeader())
        #expect(header.size == Int64(totalSize))

        try await FileSystem.shared.withFileHandle(
            forWritingAt: FilePath(destFile),
            options: .newFile(replaceExisting: false)
        ) { handle in
            try await reader.readFile(to: handle)
        }

        let extractedData = try Data(contentsOf: URL(fileURLWithPath: destFile))
        #expect(extractedData.count == totalSize)
        #expect(Array(extractedData) == content)
    }
}
#endif

// MARK: - PAX Extended Header Tests

@Suite("PAX Extended Header Tests")
struct PaxExtendedTests {

    func temporaryFilePath(name: String = "test.tar") -> FilePath {
        let tempDir = FileManager.default.temporaryDirectory.path
        let uuid = UUID().uuidString
        return FilePath("\(tempDir)/\(uuid)-\(name)")
    }

    func cleanup(_ path: FilePath) {
        try? FileManager.default.removeItem(atPath: path.string)
    }

    @Test("Long path triggers PAX header")
    func longPathTriggersPax() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        // Create a path with no valid split point (filename alone is > 100 chars)
        let longFilename = String(repeating: "a", count: 120) + ".txt"
        let longPath = "dir/" + longFilename
        #expect(longPath.utf8.count > 100)

        let content = Array("content".utf8)

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: longPath, size: Int64(content.count))
            try content.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        // The full path should be preserved via PAX
        #expect(header.path == longPath)
    }

    @Test("Very long path with PAX")
    func veryLongPathWithPax() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        // Create a path longer than 255 characters (traditional max with prefix)
        let longPath =
            String(repeating: "a", count: 50) + "/" + String(repeating: "b", count: 50) + "/" + String(repeating: "c", count: 50) + "/" + String(repeating: "d", count: 50) + "/"
            + String(repeating: "e", count: 50) + "/file.txt"
        #expect(longPath.utf8.count > 255)

        let content = Array("test".utf8)

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: longPath, size: Int64(content.count))
            try content.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        #expect(header.path == longPath)
    }

    @Test("UTF-8 path preserved")
    func utf8PathPreserved() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        let unicodePath = "目录/文件.txt"
        let content = Array("内容".utf8)

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: unicodePath, size: Int64(content.count))
            try content.withUnsafeBytes { try writer.writeContent($0) }
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        #expect(header.path == unicodePath)
    }

    @Test("Long symlink target with PAX")
    func longSymlinkTargetWithPax() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        // Create a symlink target longer than 100 characters
        let longTarget = String(repeating: "x", count: 150) + "/target.txt"

        do {
            let writer = try TarWriter(path: path)
            try writer.writeSymlink(path: "link", target: longTarget)
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        #expect(header.path == "link")
        #expect(header.linkName == longTarget)
        #expect(header.entryType == .symbolicLink)
    }
}

// MARK: - Error Handling Tests

@Suite("Tar Error Handling Tests")
struct TarErrorTests {

    @Test("Size mismatch error")
    func sizeMismatchError() throws {
        let tempPath = FilePath(FileManager.default.temporaryDirectory.path + "/\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let writer = try TarWriter(path: tempPath)
        try writer.beginFile(path: "file.txt", size: 100)

        // Only write 50 bytes
        let smallContent = [UInt8](repeating: 0x41, count: 50)
        try smallContent.withUnsafeBytes { try writer.writeContent($0) }

        // Should throw size mismatch
        #expect(throws: TarWriterError.self) {
            try writer.finalizeEntry()
        }
    }

    @Test("Write after finalize error")
    func writeAfterFinalizeError() throws {
        let tempPath = FilePath(FileManager.default.temporaryDirectory.path + "/\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        let writer = try TarWriter(path: tempPath)
        try writer.finalize()

        #expect(throws: TarWriterError.self) {
            try writer.writeDirectory(path: "dir")
        }
    }

    @Test("Reader invalid state error")
    func readerInvalidStateError() throws {
        let tempPath = FilePath(FileManager.default.temporaryDirectory.path + "/\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(atPath: tempPath.string) }

        // Create empty tar
        do {
            let writer = try TarWriter(path: tempPath)
            try writer.finalize()
        }

        let reader = try TarReader(path: tempPath)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 100, alignment: 1)
        defer { buffer.deallocate() }

        // Try to read content without calling nextHeader first
        #expect(throws: TarReaderError.self) {
            _ = try reader.readContent(into: buffer)
        }
    }
}

// MARK: - Metadata Preservation Tests

@Suite("Metadata Preservation Tests")
struct MetadataTests {

    func temporaryFilePath() -> FilePath {
        let tempDir = FileManager.default.temporaryDirectory.path
        return FilePath("\(tempDir)/\(UUID().uuidString).tar")
    }

    func cleanup(_ path: FilePath) {
        try? FileManager.default.removeItem(atPath: path.string)
    }

    @Test("UID and GID preserved")
    func uidGidPreserved() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: "file.txt", size: 0, uid: 1000, gid: 2000)
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        #expect(header.uid == 1000)
        #expect(header.gid == 2000)
    }

    @Test("Mtime preserved")
    func mtimePreserved() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        let mtime: Int64 = 1_704_067_200  // 2024-01-01 00:00:00 UTC

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: "file.txt", size: 0, mtime: mtime)
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        #expect(header.mtime == mtime)
    }

    @Test("User and group name preserved")
    func userGroupNamePreserved() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        do {
            let writer = try TarWriter(path: path)
            try writer.beginFile(path: "file.txt", size: 0, userName: "testuser", groupName: "testgroup")
            try writer.finalizeEntry()
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        let header = try #require(try reader.nextHeader())

        #expect(header.userName == "testuser")
        #expect(header.groupName == "testgroup")
    }

    @Test("Different file modes")
    func differentFileModes() throws {
        let path = temporaryFilePath()
        defer { cleanup(path) }

        let modes: [UInt32] = [0o644, 0o755, 0o600, 0o777, 0o400]

        do {
            let writer = try TarWriter(path: path)
            for (i, mode) in modes.enumerated() {
                try writer.beginFile(path: "file\(i).txt", size: 0, mode: mode)
                try writer.finalizeEntry()
            }
            try writer.finalize()
        }

        let reader = try TarReader(path: path)
        for (i, expectedMode) in modes.enumerated() {
            let header = try #require(try reader.nextHeader())
            #expect(header.path == "file\(i).txt")
            #expect(header.mode == expectedMode)
        }
    }
}

// MARK: - System Tar Interoperability Tests

@Suite("System Tar Interoperability Tests")
struct SystemTarTests {

    func temporaryDirectory() -> String {
        let tempDir = FileManager.default.temporaryDirectory.path
        let uuid = UUID().uuidString
        let path = "\(tempDir)/\(uuid)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Read tar created by system tar")
    func readSystemTar() throws {
        let workDir = temporaryDirectory()
        defer { cleanup(workDir) }

        let sourceDir = "\(workDir)/source"
        try FileManager.default.createDirectory(atPath: sourceDir, withIntermediateDirectories: true)

        let file1Content = "Hello from file1"
        let file2Content = "Content of file2 with more text"
        try file1Content.write(toFile: "\(sourceDir)/file1.txt", atomically: true, encoding: .utf8)
        try file2Content.write(toFile: "\(sourceDir)/file2.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: "\(sourceDir)/subdir", withIntermediateDirectories: true)
        try "nested".write(toFile: "\(sourceDir)/subdir/nested.txt", atomically: true, encoding: .utf8)

        let tarPath = "\(workDir)/test.tar"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", tarPath, "-C", sourceDir, "."]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let reader = try TarReader(path: FilePath(tarPath))
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buffer.deallocate() }

        var entries: [String: (TarEntryType, String)] = [:]

        while let header = try reader.nextHeader() {
            var content = ""
            if header.entryType.isRegularFile && header.size > 0 {
                var data = [UInt8]()
                while reader.contentBytesRemaining > 0 {
                    let bytesRead = try reader.readContent(into: buffer)
                    data.append(contentsOf: UnsafeRawBufferPointer(buffer)[0..<bytesRead])
                }
                content = String(decoding: data, as: UTF8.self)
            }
            entries[header.path] = (header.entryType, content)
        }

        #expect(entries["./file1.txt"]?.0 == .regular)
        #expect(entries["./file1.txt"]?.1 == file1Content)
        #expect(entries["./file2.txt"]?.0 == .regular)
        #expect(entries["./file2.txt"]?.1 == file2Content)
        #expect(entries["./subdir/nested.txt"]?.1 == "nested")
    }

    @Test("Read tar with symlink from system tar")
    func readSystemTarWithSymlink() throws {
        let workDir = temporaryDirectory()
        defer { cleanup(workDir) }

        let sourceDir = "\(workDir)/source"
        try FileManager.default.createDirectory(atPath: sourceDir, withIntermediateDirectories: true)

        try "target content".write(toFile: "\(sourceDir)/target.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: "\(sourceDir)/link.txt", withDestinationPath: "target.txt")

        let tarPath = "\(workDir)/test.tar"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", tarPath, "-C", sourceDir, "."]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let reader = try TarReader(path: FilePath(tarPath))

        var foundLink = false
        while let header = try reader.nextHeader() {
            if header.path == "./link.txt" {
                #expect(header.entryType == .symbolicLink)
                #expect(header.linkName == "target.txt")
                foundLink = true
            }
        }
        #expect(foundLink)
    }
}
