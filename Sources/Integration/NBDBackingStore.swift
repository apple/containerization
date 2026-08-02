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
import Synchronization

#if os(macOS)

/// Where an NBD export keeps the blocks it serves.
///
/// A server holds one of these and every connection to that export shares it,
/// so what one connection writes another reads back.
protocol NBDBackingStore: Sendable {
    /// The size of the export, which the server reports during the handshake.
    var size: UInt64 { get }

    /// Read `length` bytes from `offset`. Returns nil when the read fails.
    func read(offset: UInt64, length: Int) -> [UInt8]?

    /// Write `data` at `offset`. Returns false when the write fails.
    func write(offset: UInt64, data: [UInt8]) -> Bool

    /// Put anything held back where it belongs before replying to a flush.
    func flush()

    /// Release whatever the store holds.
    func close()
}

/// A store that keeps its blocks in a file.
final class NBDFileStore: NBDBackingStore {
    private let fd: Mutex<Int32>
    let size: UInt64

    init?(path: String) {
        let descriptor = open(path, O_RDWR)
        guard descriptor >= 0 else {
            return nil
        }
        var st = stat()
        guard fstat(descriptor, &st) == 0 else {
            _ = Foundation.close(descriptor)
            return nil
        }
        self.fd = Mutex(descriptor)
        self.size = UInt64(st.st_size)
    }

    func read(offset: UInt64, length: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: length)
        let read = self.fd.withLock { descriptor in
            buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, length, off_t(offset))
            }
        }
        guard read == length else {
            return nil
        }
        return buffer
    }

    func write(offset: UInt64, data: [UInt8]) -> Bool {
        self.fd.withLock { descriptor in
            data.withUnsafeBytes {
                pwrite(descriptor, $0.baseAddress, data.count, off_t(offset)) == data.count
            }
        }
    }

    func flush() {
        self.fd.withLock { _ = fsync($0) }
    }

    func close() {
        self.fd.withLock { descriptor in
            if descriptor >= 0 {
                _ = Foundation.close(descriptor)
            }
        }
    }
}

/// A store that keeps its blocks in the memory of the process serving them.
///
/// The point of holding them here rather than in a file is where they end up
/// under pressure. Memory a host process holds is pageable, so the host decides
/// when these blocks go to its own swap, and they share the one pool the rest
/// of the system draws on. Blocks in a file take space of their own instead.
///
/// Only the chunks actually written are held, so an export costs nothing until
/// something is stored in it, the way a sparse file costs nothing until it is
/// written to.
final class NBDMemoryStore: NBDBackingStore {
    /// A chunk is a page, because that is the unit a guest swaps in and out.
    /// Anything larger rounds every scattered page write up to its size, which
    /// costs both the memory the rounding wastes and the copying of the part
    /// that was not written.
    static let chunkSize = 4096

    private let chunks: Mutex<[UInt64: [UInt8]]> = Mutex([:])
    let size: UInt64

    init(size: UInt64) {
        self.size = size
    }

    /// The bytes actually held, which is what the export costs the host.
    var allocatedBytes: Int {
        self.chunks.withLock { $0.count * Self.chunkSize }
    }

    /// The most the export has ever held.
    ///
    /// What it holds right now says nothing about what passed through it, since
    /// a client that discards what it has finished with leaves an export as
    /// empty as it started. This is what a reader wanting to know whether
    /// anything was ever stored should look at.
    var peakAllocatedBytes: Int {
        self.peakChunks.withLock { $0 * Self.chunkSize }
    }

    private let peakChunks: Mutex<Int> = Mutex(0)

    func read(offset: UInt64, length: Int) -> [UInt8]? {
        guard offset + UInt64(length) <= self.size else {
            return nil
        }
        var out = [UInt8](repeating: 0, count: length)
        self.chunks.withLock { chunks in
            self.forEachSpan(offset: offset, length: length) { index, inChunk, inSpan, span in
                // A chunk never written reads back as the zeroes it started as.
                guard let chunk = chunks[index] else {
                    return
                }
                out.replaceSubrange(inSpan..<(inSpan + span), with: chunk[inChunk..<(inChunk + span)])
            }
        }
        return out
    }

    func write(offset: UInt64, data: [UInt8]) -> Bool {
        guard offset + UInt64(data.count) <= self.size else {
            return false
        }
        let held = self.chunks.withLock { chunks -> Int in
            self.forEachSpan(offset: offset, length: data.count) { index, inChunk, inSpan, span in
                var chunk = chunks[index] ?? [UInt8](repeating: 0, count: Self.chunkSize)
                chunk.replaceSubrange(inChunk..<(inChunk + span), with: data[inSpan..<(inSpan + span)])
                chunks[index] = chunk
            }
            return chunks.count
        }
        self.peakChunks.withLock { $0 = max($0, held) }
        return true
    }

    /// Nothing is held anywhere else, so a flush has nothing to do.
    func flush() {}

    func close() {
        self.chunks.withLock { $0.removeAll() }
    }

    /// Walk the chunks a request covers, handing each the range it owns.
    private func forEachSpan(
        offset: UInt64,
        length: Int,
        _ body: (_ index: UInt64, _ inChunk: Int, _ inSpan: Int, _ span: Int) -> Void
    ) {
        var remaining = length
        var at = offset
        var taken = 0
        while remaining > 0 {
            let index = at / UInt64(Self.chunkSize)
            let inChunk = Int(at % UInt64(Self.chunkSize))
            let span = min(Self.chunkSize - inChunk, remaining)
            body(index, inChunk, taken, span)
            remaining -= span
            taken += span
            at += UInt64(span)
        }
    }
}

#endif
