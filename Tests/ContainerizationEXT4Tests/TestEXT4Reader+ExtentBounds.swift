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

/// Regression tests for extent-tree parsing against malformed/hostile inodes.
/// `decodeExtents` runs on attacker-controlled bytes (an ext4 image is untrusted
/// input); a crafted extent-header `entries` count must not be able to drive
/// `Data.subdata` past the inode block buffer and trap the process.
@Suite
struct EXT4ExtentBoundsTests {

    // MARK: - Byte helpers

    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    /// Encode a 12-byte ExtentHeader (magic, entries, max, depth, generation).
    private func extentHeader(entries: UInt16, max: UInt16 = 4, depth: UInt16, magic: UInt16 = 0xf30a) -> [UInt8] {
        le16(magic) + le16(entries) + le16(max) + le16(depth) + le32(0)
    }

    /// Encode a 12-byte ExtentLeaf (block, length, startHigh, startLow).
    private func extentLeaf(block: UInt32 = 0, length: UInt16, startHigh: UInt16 = 0, startLow: UInt32) -> [UInt8] {
        le32(block) + le16(length) + le16(startHigh) + le32(startLow)
    }

    /// Build a throwaway valid ext4 image and return an open reader for it.
    /// `decodeExtents` only reads its `inodeBlock` argument for the depth-0 path,
    /// so any reader instance works.
    private func makeReader() throws -> (EXT4.EXT4Reader, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext4-extent-\(UUID().uuidString).img")
        let fmt = try EXT4.Formatter(FilePath(url.path), minDiskSize: 4 * 1024 * 1024)
        try fmt.close()
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(url.path))
        return (reader, url)
    }

    // MARK: - Tests

    /// Well-formed depth-0 extents parse; the guards don't false-reject.
    @Test
    func wellFormedDepth0ExtentsParse() throws {
        let (reader, url) = try makeReader()
        defer { try? FileManager.default.removeItem(at: url) }

        var block = extentHeader(entries: 1, depth: 0)
        block += extentLeaf(length: 2, startLow: 100)
        block += [UInt8](repeating: 0, count: 60 - block.count)  // real i_block is 60 bytes
        #expect(block.count == 60)

        let extents = try reader.decodeExtents(inodeBlock: Data(block))
        #expect(extents.count == 1)
        #expect(extents[0].start == 100)
        #expect(extents[0].end == 102)
    }

    /// `entries` claims more leaves than fit in the 60-byte inode block: must be
    /// rejected rather than reading a leaf past the end of the buffer.
    @Test
    func tooManyDepth0EntriesDoesNotTrap() throws {
        let (reader, url) = try makeReader()
        defer { try? FileManager.default.removeItem(at: url) }

        // header (12) + 4 leaves (48) = 60 bytes, but entries claims 5. The 5th
        // leaf read would span 60..<72 and trap without the bounds check.
        var block = extentHeader(entries: 5, depth: 0)
        for i in 0..<4 { block += extentLeaf(length: 1, startLow: UInt32(i + 1)) }
        #expect(block.count == 60)

        #expect(throws: EXT4.Error.invalidExtents) {
            _ = try reader.decodeExtents(inodeBlock: Data(block))
        }
    }

    /// A buffer too small to even hold the extent header yields no extents
    /// instead of trapping.
    @Test
    func shortInodeBlockReturnsEmpty() throws {
        let (reader, url) = try makeReader()
        defer { try? FileManager.default.removeItem(at: url) }

        let extents = try reader.decodeExtents(inodeBlock: Data([0x0a, 0xf3, 0x00, 0x00]))
        #expect(extents.isEmpty)
    }

    /// A non-extent inode (bad magic) yields no extents.
    @Test
    func nonExtentInodeReturnsEmpty() throws {
        let (reader, url) = try makeReader()
        defer { try? FileManager.default.removeItem(at: url) }

        var block = extentHeader(entries: 1, depth: 0, magic: 0x0000)
        block += [UInt8](repeating: 0, count: 60 - block.count)

        let extents = try reader.decodeExtents(inodeBlock: Data(block))
        #expect(extents.isEmpty)
    }
}
