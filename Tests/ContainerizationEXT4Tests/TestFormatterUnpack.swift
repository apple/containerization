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

// swiftlint:disable force_try static_over_final_class

#if os(macOS)
import ContainerizationArchive
import ContainerizationExtras
import Foundation
import Testing
import SystemPackage

@testable import ContainerizationEXT4

struct Tar2EXT4Test: ~Copyable {
    let fsPath = FilePath(
        FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("ext4.tar.img.delme", isDirectory: false))

    let xattrs: [String: Data] = [
        "foo.bar": Data([1, 2, 3]),
        "bar": Data([0, 0, 0]),
        "system.richacl.bar": Data([99, 1, 9, 1]),
        "foobar.user": Data([71, 2, 45]),
        "test.xattr.cap": Data([1, 32, 3]),
        "testing123": Data([12, 24, 45]),
        "sys.admin": Data([16, 23, 13]),
        "test.123": Data([15, 26, 54]),
        "extendedattribute.test": Data([15, 26, 54, 1, 2, 4, 6, 7, 7]),
    ]

    init() throws {
        // create layer1
        let layer1Path = FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("layer1.tar.gz", isDirectory: false)
        let layer1Archiver = try ArchiveWriter(
            configuration: ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip))
        try layer1Archiver.open(file: layer1Path)
        // create 2 directories and fill them with files
        try layer1Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir1", permissions: 0o755), data: nil)
        try layer1Archiver.writeEntry(entry: WriteEntry.file(path: "/dir1/file1", permissions: 0o644), data: nil)
        try layer1Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir2", permissions: 0o755), data: nil)
        try layer1Archiver.writeEntry(entry: WriteEntry.file(path: "/dir2/file1", permissions: 0o644), data: nil)
        try layer1Archiver.finishEncoding()

        // create layer2
        let layer2Path = FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("layer2.tar.gz", isDirectory: false)
        let layer2Archiver = try ArchiveWriter(
            configuration: ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip))
        try layer2Archiver.open(file: layer2Path)
        // create 3 directories and fill them with files and whiteouts
        try layer2Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir1", permissions: 0o755), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.file(path: "/dir1/.wh.file1", permissions: 0o644), data: nil)
        try layer2Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir2", permissions: 0o755), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.file(path: "/dir2/.wh..wh..opq", permissions: 0o644), data: nil)
        try layer2Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir3", permissions: 0o755), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.file(path: "/dir3/file1", permissions: 0o644, xattrs: xattrs), data: nil)
        try layer2Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir4", permissions: 0o755), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.file(path: "/dir4/special_ÆÂ©", permissions: 0o644), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.link(path: "/dir4/specialcharacters", permissions: 0o644, target: "special_ÆÂ©"),
            data: nil)

        // a new layer overwriting over an existing layer
        try layer2Archiver.writeEntry(entry: WriteEntry.file(path: "/dir2/file1", permissions: 0o644), data: nil)
        try layer2Archiver.finishEncoding()

        let unpacker = try EXT4.Formatter(fsPath)
        try unpacker.unpack(source: layer1Path)
        try unpacker.unpack(source: layer2Path)
        try unpacker.close()
    }

    deinit {
        try? FileManager.default.removeItem(at: fsPath.url)
    }

    @Test func testUnpackBasic() throws {
        let ext4 = try EXT4.EXT4Reader(blockDevice: fsPath)
        // just a directory
        let dir1Inode = try ext4.getInode(number: 12)
        #expect(dir1Inode.mode.isDir())
        // white out file /dir1/file1
        let dir1File1Inode = try ext4.getInode(number: 13)
        #expect(dir1File1Inode.dtime != 0)
        #expect(dir1File1Inode.linksCount == 0)  // deleted
        // white out dir /dir2
        let dir2Inode = try ext4.getInode(number: 14)
        #expect(dir2Inode.dtime == 0)
        #expect(dir2Inode.linksCount == 2)  // children deleted
        // new dir /dir3
        let dir3Inode = try ext4.getInode(number: 16)
        #expect(dir3Inode.mode.isDir())
        #expect(dir3Inode.linksCount == 2)
        // new file /dir3/file1
        let dir3File1Inode = try ext4.getInode(number: 17)
        #expect(dir3File1Inode.mode.isReg())
        #expect(dir3File1Inode.linksCount == 1)
        #expect(try ext4.getXattrsForInode(inode: dir3File1Inode) == xattrs)
        // overwritten dir /dir2
        let dir2OverwriteInode = try ext4.getInode(number: 18)
        #expect(dir2OverwriteInode.mode.isDir())
        #expect(dir2OverwriteInode.linksCount == 2)
        // /dir4/special_ÆÂ©
        let dir2File1OverwriteInode = try ext4.getInode(number: 19)
        #expect(dir2File1OverwriteInode.mode.isReg())
        #expect(dir2File1OverwriteInode.linksCount == 1)

        let specialFileInode = try ext4.getInode(number: 20)
        let bytes = Data(Mirror(reflecting: specialFileInode.block).children.compactMap { $0.value as? UInt8 })
        let specialFileTarget = try #require(FilePath(bytes), "Could not parse special file path")
        #expect(specialFileTarget.description.hasPrefix("special_ÆÂ©"))
    }
}

/// Collects progress events in a thread-safe manner.
private actor ProgressCollector {
    var events: [ProgressEvent] = []

    func append(_ newEvents: [ProgressEvent]) {
        events.append(contentsOf: newEvents)
    }

    func allEvents() -> [ProgressEvent] {
        events
    }
}

struct UnpackProgressTest {
    @Test func progressReportsAccurateSizes() async throws {
        // Create an archive with files of known sizes
        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        let archivePath = tempDir.appendingPathComponent("test.tar.gz", isDirectory: false)
        let fsPath = FilePath(tempDir.appendingPathComponent("test.ext4.img", isDirectory: false))

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Create test data with specific sizes
        let file1Data = Data(repeating: 0xAA, count: 1024)       // 1 KiB
        let file2Data = Data(repeating: 0xBB, count: 4096)       // 4 KiB
        let file3Data = Data(repeating: 0xCC, count: 512)        // 512 bytes
        let expectedTotalSize: Int64 = 1024 + 4096 + 512         // 5632 bytes

        // Build the archive
        let archiver = try ArchiveWriter(
            configuration: ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip))
        try archiver.open(file: archivePath)

        try archiver.writeEntry(entry: WriteEntry.dir(path: "/data", permissions: 0o755), data: nil)
        try archiver.writeEntry(
            entry: WriteEntry.file(path: "/data/file1.bin", permissions: 0o644, size: Int64(file1Data.count)),
            data: file1Data)
        try archiver.writeEntry(
            entry: WriteEntry.file(path: "/data/file2.bin", permissions: 0o644, size: Int64(file2Data.count)),
            data: file2Data)
        try archiver.writeEntry(
            entry: WriteEntry.file(path: "/data/file3.bin", permissions: 0o644, size: Int64(file3Data.count)),
            data: file3Data)
        // Include an empty file to verify it doesn't break size calculations
        try archiver.writeEntry(
            entry: WriteEntry.file(path: "/data/empty.bin", permissions: 0o644, size: 0),
            data: Data())
        try archiver.finishEncoding()

        // Set up progress collection
        let collector = ProgressCollector()
        let shouldPrintProgress = ProcessInfo.processInfo.environment["PRINT_UNPACK_PROGRESS"] == "1"
        let progressHandler: ProgressHandler = { events in
            if shouldPrintProgress {
                for event in events {
                    print("unpack-progress \(event.event): \(event.value)")
                }
            }
            await collector.append(events)
        }

        // Unpack with progress tracking
        let formatter = try EXT4.Formatter(fsPath)
        try formatter.unpack(source: archivePath, progress: progressHandler)
        try formatter.close()

        // Allow async progress tasks to complete
        try await Task.sleep(for: .milliseconds(100))

        // Analyze collected events
        let allEvents = await collector.allEvents()

        var reportedTotalSize: Int64 = 0
        var cumulativeSize: Int64 = 0
        var itemCount: Int64 = 0

        for event in allEvents {
            switch event.event {
            case "add-total-size":
                let value = try #require(event.value as? Int64, "add-total-size value should be Int64")
                reportedTotalSize += value
            case "add-size":
                let value = try #require(event.value as? Int64, "add-size value should be Int64")
                cumulativeSize += value
            case "add-items":
                let value = try #require(event.value as? Int, "add-items value should be Int")
                itemCount += Int64(value)
            default:
                break
            }
        }

        // Verify the progress contract
        #expect(
            reportedTotalSize == expectedTotalSize,
            "Total size should be \(expectedTotalSize) bytes, got \(reportedTotalSize)")
        #expect(
            cumulativeSize == expectedTotalSize,
            "Cumulative size should equal total size (\(expectedTotalSize)), got \(cumulativeSize)")
        #expect(
            itemCount == 5,
            "Should have processed 5 entries (1 dir + 4 files), got \(itemCount)")

        // Verify incremental progress: we should get separate add-size events for each file
        let addSizeEvents = allEvents.filter { $0.event == "add-size" }
        #expect(
            addSizeEvents.count == 4,
            "Should have 4 add-size events (one per file, including empty), got \(addSizeEvents.count)")

        // Verify individual file sizes were reported correctly
        let reportedSizes = addSizeEvents.compactMap { $0.value as? Int64 }.sorted()
        #expect(
            reportedSizes == [0, 512, 1024, 4096],
            "Individual file sizes should be [0, 512, 1024, 4096], got \(reportedSizes)")

        // Verify event-by-event behavior expected by clients:
        // total remains stable and written bytes are monotonic as progress updates arrive.
        var runningTotal: Int64?
        var runningWritten: Int64 = 0
        var previousSnapshot: (written: Int64, total: Int64?)?
        var progressSnapshotCount = 0

        for event in allEvents {
            switch event.event {
            case "add-total-size":
                let value = try #require(event.value as? Int64, "add-total-size value should be Int64")
                runningTotal = (runningTotal ?? 0) + value
            case "add-size":
                let value = try #require(event.value as? Int64, "add-size value should be Int64")
                runningWritten += value
                let currentSnapshot = (written: runningWritten, total: runningTotal)
                if let previousSnapshot {
                    #expect(
                        currentSnapshot.written >= previousSnapshot.written,
                        "Written bytes should be monotonic: \(currentSnapshot.written) < \(previousSnapshot.written)")
                    #expect(
                        currentSnapshot.total == previousSnapshot.total,
                        "Total bytes should remain stable across progress updates")
                }
                previousSnapshot = currentSnapshot
                progressSnapshotCount += 1
            default:
                break
            }
        }

        #expect(
            progressSnapshotCount == addSizeEvents.count,
            "Should produce one monotonic snapshot per add-size update")

        // Verify add-total-size comes before add-size events (first pass before second pass)
        if let totalSizeIndex = allEvents.firstIndex(where: { $0.event == "add-total-size" }),
           let firstAddSizeIndex = allEvents.firstIndex(where: { $0.event == "add-size" }) {
            #expect(
                totalSizeIndex < firstAddSizeIndex,
                "add-total-size should be reported before add-size events")
        }
    }

    @Test func progressHandlerIsOptional() throws {
        // Verify that unpacking works without a progress handler (existing behavior)
        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        let archivePath = tempDir.appendingPathComponent("test.tar.gz", isDirectory: false)
        let fsPath = FilePath(tempDir.appendingPathComponent("test.ext4.img", isDirectory: false))

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let archiver = try ArchiveWriter(
            configuration: ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip))
        try archiver.open(file: archivePath)
        try archiver.writeEntry(entry: WriteEntry.dir(path: "/test", permissions: 0o755), data: nil)
        let data = Data(repeating: 0x42, count: 100)
        try archiver.writeEntry(
            entry: WriteEntry.file(path: "/test/file.bin", permissions: 0o644, size: Int64(data.count)),
            data: data)
        try archiver.finishEncoding()

        // Unpack without progress handler - should not throw
        let formatter = try EXT4.Formatter(fsPath)
        try formatter.unpack(source: archivePath)
        try formatter.close()

        // Verify the file was unpacked correctly
        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        let children = try reader.children(of: EXT4.RootInode)
        let childNames = Set(children.map { $0.0 })
        #expect(childNames.contains("test"), "Directory 'test' should exist in unpacked filesystem")
    }
}

extension ContainerizationArchive.WriteEntry {
    static func dir(path: String, permissions: UInt16) -> WriteEntry {
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .directory
        entry.permissions = permissions
        return entry
    }

    static func file(path: String, permissions: UInt16, size: Int64? = nil, xattrs: [String: Data]? = nil) -> WriteEntry {
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .regular
        entry.permissions = permissions
        entry.size = size
        if let xattrs {
            entry.xattrs = xattrs
        }
        return entry
    }

    static func link(path: String, permissions: UInt16, target: String) -> WriteEntry {
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .symbolicLink
        entry.symlinkTarget = target
        return entry
    }
}

extension EXT4.EXT4Reader {
    fileprivate func getXattrsForInode(inode: EXT4.Inode) throws -> [String: Data] {
        var attributes: [EXT4.ExtendedAttribute] = []
        let buffer: [UInt8] = EXT4.tupleToArray(inode.inlineXattrs)
        try attributes.append(contentsOf: Self.readInlineExtendedAttributes(from: buffer))
        let block = inode.xattrBlockLow
        try self.seek(block: block)
        let buf = try self.handle.read(upToCount: Int(self.blockSize))!
        try attributes.append(contentsOf: Self.readBlockExtendedAttributes(from: [UInt8](buf)))
        var xattrs: [String: Data] = [:]
        for attribute in attributes {
            guard attribute.fullName != "system.data" else {
                continue
            }
            xattrs[attribute.fullName] = Data(attribute.value)
        }
        return xattrs
    }
}
#endif
