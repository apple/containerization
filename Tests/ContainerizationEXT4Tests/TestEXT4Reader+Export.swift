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

import ContainerizationArchive
import Foundation
import SystemPackage
import Testing

@testable import ContainerizationEXT4

/// Tests reading files with holes and unwritten extents.
///
/// The formatter can only write dense files, so each test file is written densely and then
/// its extent tree is overwritten to map file blocks onto some of those disk blocks.
@Suite
struct EXT4SparseFileTests {
    private static let blockSize: UInt64 = 4096

    struct SparseExtent {
        var logical: UInt32
        /// Which block of the file's original dense content to map here.
        var sourceBlock: UInt32
        var length: UInt16
        var unwritten = false
    }

    /// Ways to damage an extent tree when it is written.
    enum Corruption {
        case noExtentTree
        case tooManyEntries
        case highPhysicalBlock
        case highLeafBlock
        case badLeafMagic
        case leafNotDepthZero
    }

    struct SparseFile: CustomTestStringConvertible {
        let path: String
        /// Blocks of test data written before the extent tree is replaced.
        let sourceBlocks: Int
        let size: UInt64
        let extents: [SparseExtent]
        /// Store the extents in a separate block that the inode points to (tree depth 1).
        var indexed = false
        var corruption: Corruption?

        var testDescription: String { path }
    }

    // Layouts list one character per file block: D (or Dn, source block n) is data, _ a hole, U unwritten.
    private static let sparseFiles: [SparseFile] = [
        // D D _ _ _ D D
        SparseFile(
            path: "/hole-middle", sourceBlocks: 4, size: 7 * blockSize,
            extents: [
                SparseExtent(logical: 0, sourceBlock: 0, length: 2),
                SparseExtent(logical: 5, sourceBlock: 2, length: 2),
            ]),
        // _ _ _ D D
        SparseFile(
            path: "/hole-start", sourceBlocks: 2, size: 5 * blockSize,
            extents: [SparseExtent(logical: 3, sourceBlock: 0, length: 2)]),
        // D D _ _ _ _ _(partial)
        SparseFile(
            path: "/hole-end", sourceBlocks: 2, size: 6 * blockSize + 100,
            extents: [SparseExtent(logical: 0, sourceBlock: 0, length: 2)]),
        // D3 _ D1 _ _ D0 _ _ D2(partial), with blocks out of order on disk.
        SparseFile(
            path: "/hole-many", sourceBlocks: 4, size: 8 * blockSize + 123,
            extents: [
                SparseExtent(logical: 0, sourceBlock: 3, length: 1),
                SparseExtent(logical: 2, sourceBlock: 1, length: 1),
                SparseExtent(logical: 5, sourceBlock: 0, length: 1),
                SparseExtent(logical: 8, sourceBlock: 2, length: 1),
            ]),
        // D U U D, like a range preallocated with fallocate(2).
        SparseFile(
            path: "/unwritten", sourceBlocks: 4, size: 4 * blockSize,
            extents: [
                SparseExtent(logical: 0, sourceBlock: 0, length: 1),
                SparseExtent(logical: 1, sourceBlock: 1, length: 2, unwritten: true),
                SparseExtent(logical: 3, sourceBlock: 3, length: 1),
            ]),
        // Entirely a hole, e.g. `truncate -s`.
        SparseFile(path: "/hole-only", sourceBlocks: 1, size: 3 * blockSize + 5, extents: []),
        // D0 _ _ _ D1 U _ D2 _ D3 D4 _ D0 _: too many extents to fit in the inode.
        SparseFile(
            path: "/hole-indexed", sourceBlocks: 5, size: 14 * blockSize,
            extents: [
                SparseExtent(logical: 0, sourceBlock: 0, length: 1),
                SparseExtent(logical: 4, sourceBlock: 1, length: 1),
                SparseExtent(logical: 5, sourceBlock: 2, length: 1, unwritten: true),
                SparseExtent(logical: 7, sourceBlock: 2, length: 1),
                SparseExtent(logical: 9, sourceBlock: 3, length: 2),
                SparseExtent(logical: 12, sourceBlock: 0, length: 1),
            ],
            indexed: true),
        // D _ (EOF) U U: preallocated past the end of the file, like `fallocate --keep-size`.
        SparseFile(
            path: "/unwritten-past-eof", sourceBlocks: 3, size: 2 * blockSize + 10,
            extents: [
                SparseExtent(logical: 0, sourceBlock: 0, length: 1),
                SparseExtent(logical: 3, sourceBlock: 1, length: 2, unwritten: true),
            ]),
        // D0, a 1.2 MiB hole, then 1.2 MiB of data ending mid-block: crosses the 1 MiB read chunks.
        SparseFile(
            path: "/large", sourceBlocks: 300, size: 598 * blockSize + 7,
            extents: [
                SparseExtent(logical: 0, sourceBlock: 0, length: 1),
                SparseExtent(logical: 300, sourceBlock: 1, length: 299),
            ]),
    ]

    /// Extent trees the reader must reject with `invalidExtents`.
    private static let invalidFiles: [SparseFile] = [
        SparseFile(
            path: "/no-extent-tree", sourceBlocks: 1, size: blockSize,
            extents: [SparseExtent(logical: 0, sourceBlock: 0, length: 1)], corruption: .noExtentTree),
        SparseFile(
            path: "/too-many-entries", sourceBlocks: 1, size: blockSize,
            extents: [SparseExtent(logical: 0, sourceBlock: 0, length: 1)], corruption: .tooManyEntries),
        SparseFile(
            path: "/out-of-order", sourceBlocks: 2, size: 4 * blockSize,
            extents: [
                SparseExtent(logical: 2, sourceBlock: 0, length: 1),
                SparseExtent(logical: 0, sourceBlock: 1, length: 1),
            ]),
        SparseFile(
            path: "/overlapping", sourceBlocks: 3, size: 4 * blockSize,
            extents: [
                SparseExtent(logical: 0, sourceBlock: 0, length: 2),
                SparseExtent(logical: 1, sourceBlock: 2, length: 1),
            ]),
        SparseFile(
            path: "/high-physical-block", sourceBlocks: 1, size: blockSize,
            extents: [SparseExtent(logical: 0, sourceBlock: 0, length: 1)], corruption: .highPhysicalBlock),
        SparseFile(
            path: "/high-leaf-block", sourceBlocks: 1, size: blockSize,
            extents: [SparseExtent(logical: 0, sourceBlock: 0, length: 1)], indexed: true, corruption: .highLeafBlock),
        SparseFile(
            path: "/bad-leaf-magic", sourceBlocks: 1, size: blockSize,
            extents: [SparseExtent(logical: 0, sourceBlock: 0, length: 1)], indexed: true, corruption: .badLeafMagic),
        SparseFile(
            path: "/leaf-not-depth-zero", sourceBlocks: 1, size: blockSize,
            extents: [SparseExtent(logical: 0, sourceBlock: 0, length: 1)], indexed: true, corruption: .leafNotDepthZero),
    ]

    @Test(arguments: invalidFiles)
    func invalidExtentTreesAreRejected(_ file: SparseFile) throws {
        let image = try buildImage(sparseFiles: [file], dense: [:])
        defer { try? FileManager.default.removeItem(at: image.url) }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("ext4-export-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: archive) }

        // Some corruptions are caught when the reader first walks the tree, others only when the file is read.
        #expect(throws: EXT4.Error.invalidExtents) {
            try EXT4.EXT4Reader(blockDevice: FilePath(image.url.path)).export(archive: FilePath(archive.path))
        }
        // readFile returns no data, rather than throwing, for files without an extent tree.
        if file.corruption != .noExtentTree {
            #expect(throws: EXT4.Error.invalidExtents) {
                try EXT4.EXT4Reader(blockDevice: FilePath(image.url.path)).readFile(at: FilePath(file.path))
            }
        }
    }

    @Test func exportPreservesSparseFiles() throws {
        let image = try buildImage()
        defer { try? FileManager.default.removeItem(at: image.url) }

        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("ext4-export-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.url.path))
        try reader.export(archive: FilePath(archive.path))

        var exported: [String: (size: Int64?, data: Data)] = [:]
        for (entry, data) in try ArchiveReader(file: archive) where entry.fileType == .regular {
            let path = "/" + String((entry.path ?? "").trimmingPrefix("./").trimmingPrefix("/"))
            exported[path] = (entry.size, data)
        }

        #expect(Set(exported.keys) == Set(image.expected.keys))
        for (path, expected) in image.expected {
            let actual = try #require(exported[path], "\(path) missing from archive")
            #expect(actual.size == Int64(expected.count), "\(path) header size")
            #expect(Self.firstDifference(actual.data, expected) == nil, "\(path) content differs")
        }
    }

    @Test func readFileZeroFillsHoles() throws {
        let image = try buildImage()
        defer { try? FileManager.default.removeItem(at: image.url) }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.url.path))

        for (path, expected) in image.expected {
            let whole = try reader.readFile(at: FilePath(path))
            #expect(Self.firstDifference(whole, expected) == nil, "\(path) content differs")

            // A ranged read that starts mid-block and spans holes and extent boundaries.
            let offset = min(Self.blockSize + 10, UInt64(expected.count))
            let count = 3 * Int(Self.blockSize)
            let ranged = try reader.readFile(at: FilePath(path), offset: offset, count: count)
            let want = expected.subdata(in: Int(offset)..<min(Int(offset) + count, expected.count))
            #expect(Self.firstDifference(ranged, want) == nil, "\(path) ranged read differs")
        }
    }

    @Test func exportFailsInsteadOfPaddingShortReads() throws {
        // An extent past the end of the device can't be read. Export must throw rather than
        // let the archive writer pad the entry with zeros.
        let file = SparseFile(
            path: "/broken", sourceBlocks: 1, size: 2 * Self.blockSize,
            extents: [SparseExtent(logical: 0, sourceBlock: 0x00ff_0000, length: 2)])
        let image = try buildImage(sparseFiles: [file], dense: [:])
        defer { try? FileManager.default.removeItem(at: image.url) }

        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("ext4-export-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.url.path))
        #expect(throws: EXT4.Error.self) {
            try reader.export(archive: FilePath(archive.path))
        }
    }

    // MARK: - Image construction

    private static let denseFiles: [String: Data] = [
        "/dense": Data(pattern(seed: 0xd0, count: 3 * Int(blockSize) + 777)),
        "/small": Data("hello".utf8),
        "/empty": Data(),
    ]

    private func buildImage(
        sparseFiles: [SparseFile] = Self.sparseFiles,
        dense: [String: Data] = Self.denseFiles
    ) throws -> (url: URL, expected: [String: Data]) {
        let bs = Int(Self.blockSize)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ext4-sparse-\(UUID().uuidString).img")
        var expected = dense

        var sources: [String: Data] = [:]
        let formatter = try EXT4.Formatter(FilePath(url.path), blockSize: UInt32(bs), minDiskSize: 8.mib())
        for (index, file) in sparseFiles.enumerated() {
            let source = Data(Self.pattern(seed: UInt32(index + 1), count: file.sourceBlocks * bs))
            sources[file.path] = source
            try create(formatter, file.path, source)
            if file.indexed {
                try create(formatter, file.path + ".leaf", Data(count: bs))
            }
        }
        for (path, data) in dense {
            try create(formatter, path, data)
        }
        try formatter.close()

        // Find each file's inode and data blocks before patching the image.
        var patches: [(file: SparseFile, inodeOffset: UInt64, physicalStart: UInt32, leafBlock: UInt32?)] = []
        do {
            let reader = try EXT4.EXT4Reader(blockDevice: FilePath(url.path))
            for file in sparseFiles {
                let physical = try #require(try reader.getExtents(inode: reader.stat(FilePath(file.path)).inodeNumber))
                try #require(physical.count == 1)
                var leafBlock: UInt32?
                if file.indexed {
                    let leaf = try #require(try reader.getExtents(inode: reader.stat(FilePath(file.path + ".leaf")).inodeNumber))
                    leafBlock = try #require(leaf.first).start
                }
                let offset = try inodeOffset(reader, file.path)
                patches.append((file, offset, physical[0].start, leafBlock))
            }
        }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let blockOffset = try #require(MemoryLayout<EXT4.Inode>.offset(of: \EXT4.Inode.block))
        let sizeLowOffset = try #require(MemoryLayout<EXT4.Inode>.offset(of: \EXT4.Inode.sizeLow))
        let sizeHighOffset = try #require(MemoryLayout<EXT4.Inode>.offset(of: \EXT4.Inode.sizeHigh))
        let iblockSize = MemoryLayout.size(ofValue: EXT4.Inode().block)
        for (file, offset, physicalStart, leafBlock) in patches {
            let leaves = file.extents.map { extent in
                EXT4.ExtentLeaf(
                    block: extent.logical,
                    length: extent.length + (extent.unwritten ? UInt16(EXT4.MaxBlocksPerExtent) : 0),
                    startHigh: file.corruption == .highPhysicalBlock ? 1 : 0,
                    startLow: physicalStart + extent.sourceBlock)
            }
            var iblock: [UInt8]
            if let leafBlock {
                let leafHeader = Self.extentHeader(
                    entries: leaves.count, max: Self.nodeCapacity(bs), depth: file.corruption == .leafNotDepthZero ? 1 : 0,
                    magic: file.corruption == .badLeafMagic ? 0 : EXT4.ExtentHeaderMagic)
                var node = Self.bytes(of: leafHeader)
                for leaf in leaves {
                    node += Self.bytes(of: leaf)
                }
                node += [UInt8](repeating: 0, count: bs - node.count)
                try handle.seek(toOffset: UInt64(leafBlock) * Self.blockSize)
                try handle.write(contentsOf: node)
                expected[file.path + ".leaf"] = Data(node)

                iblock = Self.bytes(of: Self.extentHeader(entries: 1, max: Self.nodeCapacity(iblockSize), depth: 1))
                let leafHigh: UInt16 = file.corruption == .highLeafBlock ? 1 : 0
                iblock += Self.bytes(of: EXT4.ExtentIndex(block: 0, leafLow: leafBlock, leafHigh: leafHigh, unused: 0))
            } else {
                let capacity = Self.nodeCapacity(iblockSize)
                let entries = file.corruption == .tooManyEntries ? Int(capacity) + 1 : leaves.count
                iblock = Self.bytes(of: Self.extentHeader(entries: entries, max: capacity, depth: 0))
                for leaf in leaves {
                    iblock += Self.bytes(of: leaf)
                }
            }
            if file.corruption == .noExtentTree {
                iblock = []
            }
            try #require(iblock.count <= iblockSize, "\(file.path): too many extents to fit in the inode")
            iblock += [UInt8](repeating: 0, count: iblockSize - iblock.count)
            try handle.seek(toOffset: offset + UInt64(blockOffset))
            try handle.write(contentsOf: iblock)
            try handle.seek(toOffset: offset + UInt64(sizeLowOffset))
            try handle.write(contentsOf: Self.bytes(of: file.size.lo))
            try handle.seek(toOffset: offset + UInt64(sizeHighOffset))
            try handle.write(contentsOf: Self.bytes(of: file.size.hi))

            // Expected: zeros, except where written extents map source blocks, cut to the file size.
            if let source = sources[file.path] {
                var content = Data(count: Int(file.size))
                for extent in file.extents where !extent.unwritten {
                    let start = Int(extent.logical) * bs
                    let end = min(start + Int(extent.length) * bs, content.count)
                    guard start < end else { continue }
                    let from = Int(extent.sourceBlock) * bs
                    if from + (end - start) <= source.count {
                        content.replaceSubrange(start..<end, with: source.subdata(in: from..<from + (end - start)))
                    }
                }
                expected[file.path] = content
            }
        }
        return (url, expected)
    }

    private func create(_ formatter: EXT4.Formatter, _ path: String, _ data: Data) throws {
        let stream = InputStream(data: data)
        stream.open()
        defer { stream.close() }
        try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream)
    }

    private func inodeOffset(_ reader: EXT4.EXT4Reader, _ path: String) throws -> UInt64 {
        let number = try reader.stat(FilePath(path)).inodeNumber
        let sb = reader.superBlock
        let descriptor = try reader.getGroupDescriptor((number - 1) / sb.inodesPerGroup)
        let index = UInt64((number - 1) % sb.inodesPerGroup)
        return UInt64(descriptor.inodeTableLow) * Self.blockSize + index * UInt64(sb.inodeSize)
    }

    // MARK: - Byte helpers

    private static func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeLittleEndianBytes(of: value) { Array($0) }
    }

    /// Number of extent entries that fit in a node of `bytes` bytes after its header.
    private static func nodeCapacity(_ bytes: Int) -> UInt16 {
        UInt16((bytes - MemoryLayout<EXT4.ExtentHeader>.size) / MemoryLayout<EXT4.ExtentLeaf>.size)
    }

    private static func extentHeader(entries: Int, max: UInt16, depth: UInt16, magic: UInt16 = EXT4.ExtentHeaderMagic) -> EXT4.ExtentHeader {
        EXT4.ExtentHeader(magic: magic, entries: UInt16(entries), max: max, depth: depth, generation: 0)
    }

    /// Repeatable pseudo-random bytes, so a misplaced or zeroed block shows up as a mismatch.
    private static func pattern(seed: UInt32, count: Int) -> [UInt8] {
        var state = seed &* 2_654_435_761 | 1
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        }
    }

    private static func firstDifference(_ actual: Data, _ expected: Data) -> String? {
        if let offset = zip(actual, expected).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            return String(format: "first mismatch at offset 0x%x", offset)
        }
        if actual.count != expected.count {
            return "length \(actual.count), expected \(expected.count)"
        }
        return nil
    }
}
