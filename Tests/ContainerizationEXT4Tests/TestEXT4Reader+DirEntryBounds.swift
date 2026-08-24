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

import Foundation
import SystemPackage
import Testing

@testable import ContainerizationEXT4

/// Regression tests for directory-entry parsing against malformed/hostile ext4
/// directory blocks. `getDirEntries` runs on attacker-controlled bytes (an ext4
/// image is untrusted input); a crafted `nameLength`/`recordLength` must not be
/// able to drive `Data.subdata` past the block buffer and trap the process.
@Suite
struct EXT4DirEntryBoundsTests {

    // MARK: - Byte helpers

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }

    /// Encode the fixed 8-byte on-disk directory-entry header
    /// (inode:4, recordLength:2, nameLength:1, fileType:1), little-endian.
    private func header(inode: UInt32, recordLength: UInt16, nameLength: UInt8, fileType: UInt8 = 1) -> [UInt8] {
        le32(inode) + le16(recordLength) + [nameLength, fileType]
    }

    /// Build a throwaway valid ext4 image and return an open reader for it.
    /// `getDirEntries` does not touch reader state, so any reader instance works.
    private func makeReader() throws -> (EXT4.EXT4Reader, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext4-direntry-\(UUID().uuidString).img")
        let fmt = try EXT4.Formatter(FilePath(url.path), minDiskSize: 4 * 1024 * 1024)
        try fmt.close()
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(url.path))
        return (reader, url)
    }

    // MARK: - Tests

    /// Well-formed block: both entries parse, guards do not false-reject.
    @Test
    func wellFormedBlockParsesAllEntries() throws {
        let (reader, url) = try makeReader()
        defer { try? FileManager.default.removeItem(at: url) }

        var block = [UInt8]()
        // entry "aa" (inode 11), record 16 = 8 header + 2 name + 6 pad
        block += header(inode: 11, recordLength: 16, nameLength: 2)
        block += Array("aa".utf8)
        block += [UInt8](repeating: 0, count: 16 - 8 - 2)
        // entry "bb" (inode 12), record 16
        block += header(inode: 12, recordLength: 16, nameLength: 2)
        block += Array("bb".utf8)
        block += [UInt8](repeating: 0, count: 16 - 8 - 2)
        #expect(block.count == 32)

        let entries = try reader.getDirEntries(dirTree: Data(block))
        #expect(entries.count == 2)
        #expect(entries[0].0 == "aa")
        #expect(entries[0].1 == 11)
        #expect(entries[1].0 == "bb")
        #expect(entries[1].1 == 12)
    }

    /// Fewer than a full header remain at the tail: must stop, not trap when
    /// loading the fixed header past the end of the block.
    @Test
    func shortHeaderTailDoesNotTrap() throws {
        let (reader, url) = try makeReader()
        defer { try? FileManager.default.removeItem(at: url) }

        var block = [UInt8]()
        // one valid entry occupying bytes 0..<12
        block += header(inode: 11, recordLength: 12, nameLength: 4)
        block += Array("aaaa".utf8)
        // 4 trailing bytes: offset lands at 12 with only 4 (< 8) bytes left
        block += [UInt8](repeating: 0, count: 4)
        #expect(block.count == 16)

        let entries = try reader.getDirEntries(dirTree: Data(block))
        #expect(entries.count == 1)
        #expect(entries[0].0 == "aaaa")
        #expect(entries[0].1 == 11)
    }

    /// `nameLength` larger than the entry's own `recordLength`: must be rejected
    /// rather than reading a name that runs past the record/block.
    @Test
    func nameLongerThanRecordDoesNotTrap() throws {
        let (reader, url) = try makeReader()
        defer { try? FileManager.default.removeItem(at: url) }

        // recordLength 16 (>= 8, passes the existing guard) but nameLength 200,
        // so a name read would span 8..<208 and trap.
        var block = header(inode: 12, recordLength: 16, nameLength: 200)
        block += [UInt8](repeating: 0, count: 8)  // pad block out to 16 bytes
        #expect(block.count == 16)

        let entries = try reader.getDirEntries(dirTree: Data(block))
        #expect(entries.isEmpty)
    }

    /// `recordLength` claims room for the name but the block itself is too small:
    /// the name read would run off the end of the buffer and trap.
    @Test
    func nameRunningPastBlockDoesNotTrap() throws {
        let (reader, url) = try makeReader()
        defer { try? FileManager.default.removeItem(at: url) }

        // recordLength 512 admits nameLength 100 (512 >= 8 + 100), but the block
        // is only 16 bytes, so name bytes 8..<108 lie outside the buffer.
        var block = header(inode: 12, recordLength: 512, nameLength: 100)
        block += [UInt8](repeating: 0, count: 8)  // block is only 16 bytes total
        #expect(block.count == 16)

        let entries = try reader.getDirEntries(dirTree: Data(block))
        #expect(entries.isEmpty)
    }
}
