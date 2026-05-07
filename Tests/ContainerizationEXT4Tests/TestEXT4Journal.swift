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

@testable import ContainerizationEXT4

/// Structural validation tests for journaled EXT4 filesystems.
///
/// Each test creates a minimal image with a specific journal mode, then reads the
/// superblock back via `EXT4.EXT4Reader` and asserts the invariants that the Linux
/// kernel checks before mounting:
///
/// - **Geometry**: `fileSize == blocksCount * blockSize`
///   (the exact invariant behind "bad geometry: block count N exceeds size of device")
/// - **Additive sizing**: `fileSize > minDiskSize`
///   (the journal grows the image rather than carving into the usable capacity)
/// - **Feature flag**: `featureCompat` has `hasJournal` set
/// - **Journal inode**: `journalInum == EXT4.JournalInode` (inode 8)
/// - **Mount options**: `defaultMountOpts` matches the requested mode
@Suite(.serialized)
struct JournalFormatTests {
    let minDiskSize: UInt64 = 128.mib()

    // MARK: - Per-mode tests

    @Test func writeback() throws {
        let path = tmpPath("ext4-journal-writeback")
        defer { cleanup(path) }
        let formatter = try EXT4.Formatter(path, minDiskSize: minDiskSize, journal: .init(defaultMode: .writeback))
        try writeHello(formatter, content: "writeback")
        try formatter.close()
        // Writeback mode: only journal metadata is committed to disk before the data.
        // defaultMountOpts encodes this as 0x0060 (data=writeback | barrier).
        try verifyStructure(at: path, expectedMountOpts: EXT4.DefaultMountOpts.journalWriteback)
    }

    @Test func ordered() throws {
        let path = tmpPath("ext4-journal-ordered")
        defer { cleanup(path) }
        let formatter = try EXT4.Formatter(path, minDiskSize: minDiskSize, journal: .init(defaultMode: .ordered))
        try writeHello(formatter, content: "ordered")
        try formatter.close()
        // Ordered mode (the Linux default): data blocks are written before the journal commit.
        // defaultMountOpts encodes this as 0x0040 (data=ordered | barrier).
        try verifyStructure(at: path, expectedMountOpts: EXT4.DefaultMountOpts.journalOrdered)
    }

    @Test func journalData() throws {
        let path = tmpPath("ext4-journal-data")
        defer { cleanup(path) }
        let formatter = try EXT4.Formatter(path, minDiskSize: minDiskSize, journal: .init(defaultMode: .journal))
        try writeHello(formatter, content: "journal")
        try formatter.close()
        // Data journaling mode: data and metadata are both journaled.
        // defaultMountOpts encodes this as 0x0020 (data=journal | barrier).
        try verifyStructure(at: path, expectedMountOpts: EXT4.DefaultMountOpts.journalData)
    }

    // MARK: - Shared structural helper

    private func verifyStructure(at path: FilePath, expectedMountOpts: UInt32) throws {
        let fileSize = try fileByteCount(at: path)
        let reader = try EXT4.EXT4Reader(blockDevice: path)
        let sb = reader.superBlock

        let blocksCount = UInt64(sb.blocksCountLow) | (UInt64(sb.blocksCountHigh) << 32)
        let blockSize = UInt64(sb.blockSize)

        // The Linux kernel rejects mounts where the superblock's block count implies
        // a larger device than the actual file backing the filesystem.
        #expect(fileSize == blocksCount * blockSize, "geometry mismatch: fileSize=\(fileSize), blocksCount=\(blocksCount), blockSize=\(blockSize)")

        // The journal is additive overhead; the image must be larger than minDiskSize.
        #expect(fileSize > minDiskSize, "journal did not grow the image: fileSize=\(fileSize), minDiskSize=\(minDiskSize)")

        // The COMPAT_HAS_JOURNAL flag must be set for the kernel to look for inode 8.
        #expect(sb.featureCompat & EXT4.CompatFeature.hasJournal.rawValue != 0, "COMPAT_HAS_JOURNAL not set in featureCompat (0x\(String(sb.featureCompat, radix: 16)))")

        // The journal inode number recorded in the superblock must point at inode 8.
        #expect(sb.journalInum == EXT4.JournalInode, "journalInum=\(sb.journalInum), expected \(EXT4.JournalInode)")

        // The default mount options must reflect the requested journaling mode.
        #expect(sb.defaultMountOpts == expectedMountOpts, "defaultMountOpts=0x\(String(sb.defaultMountOpts, radix: 16)), expected 0x\(String(expectedMountOpts, radix: 16))")
    }

    // MARK: - Filesystem population helpers

    private func writeHello(_ formatter: EXT4.Formatter, content: String) throws {
        try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        let stream = InputStream(data: Data(content.utf8))
        stream.open()
        defer { stream.close() }
        try formatter.create(
            path: FilePath("/data/hello.txt"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o644),
            buf: stream)
    }

    // MARK: - File helpers

    private func tmpPath(_ name: String) -> FilePath {
        FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)-\(UUID().uuidString).img", isDirectory: false)
                .path
        )
    }

    private func cleanup(_ path: FilePath) {
        try? FileManager.default.removeItem(atPath: path.string)
    }

    private func fileByteCount(at path: FilePath) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: path.string)
        guard let size = attrs[.size] as? UInt64 else {
            throw CocoaError(.fileReadUnknown)
        }
        return size
    }
}

/// Tests that the UInt32 block-count overflow guards fire at the right points.
struct JournalOverflowTests {
    // (UInt32.max + 1) blocks at the minimum block size triggers the guard in init()
    // before any file is created, so no cleanup is needed.
    @Test func initRejectsBlockCountOverflowingUInt32() {
        let path = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false).path)
        #expect(throws: EXT4.Formatter.Error.self) {
            try EXT4.Formatter(path, blockSize: 1024, minDiskSize: (UInt64(UInt32.max) + 1) * 1024)
        }
    }

    // minDiskSize is exactly at the UInt32 block count limit; adding any journal pushes
    // newSize / blockSize above UInt32.max. The guard in close() fires before the bitmap
    // loop, so this test completes quickly despite the large sparse file.
    @Test func closeRejectsJournalExpansionOverflowingUInt32() throws {
        let path = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false).path)
        defer { try? FileManager.default.removeItem(atPath: path.string) }
        let formatter = try EXT4.Formatter(
            path, blockSize: 1024, minDiskSize: UInt64(UInt32.max) * 1024,
            journal: .init(defaultMode: .writeback))
        #expect(throws: EXT4.Formatter.Error.self) {
            try formatter.close()
        }
    }
}
