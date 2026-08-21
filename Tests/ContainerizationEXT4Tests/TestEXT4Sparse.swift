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

/// A formatted image holds its structures where a reader expects them and
/// nothing anywhere else. What an empty filesystem costs the host it is stored
/// on is the sum of the structures actually written, not of the capacity the
/// filesystem was given: the journal and the free half of the inode table read
/// as zero over spans measured in gigabytes at container capacities, and a
/// filesystem holding those as holes reads the same as one holding them as
/// written zeros.
struct Ext4SparseTests {
    /// The blocks a file occupies, which is what the filesystem holding it
    /// gives up, as opposed to the length the file reports.
    private func allocatedBytes(of path: FilePath) throws -> UInt64 {
        var st = stat()
        guard stat(path.string, &st) == 0 else {
            throw EXT4.Formatter.Error.notFound(path)
        }
        return UInt64(st.st_blocks) * 512
    }

    private func format(capacity: UInt64, journal: EXT4.JournalConfig?) throws -> (path: FilePath, allocated: UInt64, length: UInt64) {
        let path = FilePath(
            FileManager.default.uniqueTemporaryDirectory()
                .appendingPathComponent("ext4.img.delme.sparse", isDirectory: false))
        let formatter = try EXT4.Formatter(path, minDiskSize: capacity, journal: journal)
        try formatter.create(path: FilePath("/test"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.close()
        let handle = try FileHandle(forReadingFrom: path.url)
        let length = try handle.seekToEnd()
        try handle.close()
        return (path, try allocatedBytes(of: path), length)
    }

    /// An image formatted at the capacity a container's filesystem is given
    /// reports that capacity and occupies a small fraction of it. The bound is
    /// far above what the structures of an empty filesystem come to and far
    /// below the gigabyte a written-out journal alone would add, so it holds
    /// whatever the layout does and fails if a span goes back to being written.
    @Test func emptyImageAtContainerCapacityOccupiesLittle() throws {
        let capacity: UInt64 = 512.gib()
        let result = try format(capacity: capacity, journal: .init(defaultMode: .ordered))
        defer { try? FileManager.default.removeItem(at: result.path.url) }

        #expect(result.length >= capacity)
        #expect(
            result.allocated < 256.mib(),
            "an empty image of \(capacity) bytes occupies \(result.allocated) bytes"
        )
    }

    /// The journal is the largest of those spans, so an image given one and an
    /// image given none occupy nearly the same.
    @Test func theJournalCostsLittleUntilItHoldsSomething() throws {
        let capacity: UInt64 = 512.gib()
        let journaled = try format(capacity: capacity, journal: .init(defaultMode: .ordered))
        defer { try? FileManager.default.removeItem(at: journaled.path.url) }
        let plain = try format(capacity: capacity, journal: nil)
        defer { try? FileManager.default.removeItem(at: plain.path.url) }

        #expect(
            journaled.allocated < plain.allocated + 64.mib(),
            "journaled image occupies \(journaled.allocated) against \(plain.allocated) without one"
        )
    }
}
