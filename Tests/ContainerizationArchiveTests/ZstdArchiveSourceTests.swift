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
import Testing
import libzstd

@testable import ContainerizationArchive

struct ZstdArchiveSourceTests {
    @Test(arguments: [false, true], [0, 16, ZSTD_DStreamInSize() * 2])
    func completeFramesAtEOF(concatenated: Bool, skippableSize: Int) throws {
        let directory = try #require(createTemporaryDirectory(baseName: "ZstdArchiveSourceTests"))
        defer { try? FileManager.default.removeItem(at: directory) }

        // Exceed the decoder's output buffer to exercise buffered output at EOF.
        let content = Data(repeating: 0x61, count: ZSTD_DStreamOutSize() * 2)
        let tar = try makeTar(content: content, in: directory)
        var compressed: Data
        if concatenated {
            compressed = try compress(Data(tar.prefix(512))) + compress(Data(tar.dropFirst(512)))
        } else {
            compressed = try compress(tar)
        }
        if skippableSize > 0 {
            compressed.append(skippableFrame(size: skippableSize))
        }

        let archive = directory.appendingPathComponent("test.tar.zst")
        try compressed.write(to: archive)
        let reader = try ArchiveReader(format: .paxRestricted, filter: .zstd, file: archive)
        let destination = directory.appendingPathComponent("extracted")

        #expect(try reader.extractContents(to: destination).isEmpty)
        #expect(try Data(contentsOf: destination.appendingPathComponent("foo")) == content)
    }

    @Test(arguments: [false, true])
    func truncatedFinalFrameFails(skippable: Bool) throws {
        let directory = try #require(createTemporaryDirectory(baseName: "ZstdArchiveSourceTests"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let tar = try makeTar(content: Data(repeating: 0x61, count: 512), in: directory)
        // Complete the tar in the first frame, then truncate a following frame.
        // A completed earlier frame must not hide an incomplete final frame.
        var compressed = try compress(tar)
        let finalFrame = try skippable ? skippableFrame(size: 16) : compress(Data())
        compressed.append(finalFrame.dropLast())

        let archive = directory.appendingPathComponent("truncated.tar.zst")
        try compressed.write(to: archive)
        #expect(throws: ArchiveError.self) {
            let reader = try ArchiveReader(format: .paxRestricted, filter: .zstd, file: archive)
            _ = try reader.extractContents(to: directory.appendingPathComponent("extracted"))
        }
    }

    @Test func emptyInputFails() throws {
        let directory = try #require(createTemporaryDirectory(baseName: "ZstdArchiveSourceTests"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("empty.tar.zst")
        try Data().write(to: archive)

        #expect(throws: ArchiveError.self) {
            let reader = try ArchiveReader(format: .paxRestricted, filter: .zstd, file: archive)
            _ = try reader.extractContents(to: directory.appendingPathComponent("extracted"))
        }
    }

    private func makeTar(content: Data, in directory: URL) throws -> Data {
        let archive = directory.appendingPathComponent("test.tar")
        let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: archive)
        let entry = WriteEntry()
        entry.path = "foo"
        entry.fileType = .regular
        entry.permissions = 0o644
        entry.size = numericCast(content.count)
        try writer.writeEntry(entry: entry, data: content)
        try writer.finishEncoding()

        // Omit terminal zero blocks so libarchive must read through to physical
        // EOF instead of stopping before the zstd reader sees the end of input.
        let tar = try Data(contentsOf: archive)
        return Data(tar.prefix(512 + ((content.count + 511) / 512) * 512))
    }

    private func compress(_ data: Data) throws -> Data {
        var compressed = Data(count: ZSTD_compressBound(data.count))
        let size = compressed.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                ZSTD_compress(output.baseAddress, output.count, input.baseAddress, input.count, 1)
            }
        }
        try #require(ZSTD_isError(size) == 0)
        compressed.count = size
        return compressed
    }

    private func skippableFrame(size: Int) -> Data {
        var frame = Data([0x50, 0x2a, 0x4d, 0x18])
        var length = UInt32(size).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(Data(repeating: 0, count: size))
        return frame
    }
}
