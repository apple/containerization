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

#if os(Linux)
import ContainerizationOS
import Foundation
import Testing

struct SwapTests {
    private func makeArea(pages: UInt64, pageSize: Int) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("swap-\(UUID().uuidString)").path
        try #require(
            FileManager.default.createFile(
                atPath: path,
                contents: Data(count: Int(pages) * pageSize)
            )
        )
        return path
    }

    /// The header the kernel reads back is the one `mkswap` writes: version 1
    /// and the last usable page at the documented offsets, and the magic in the
    /// final bytes of the first page.
    @Test func formatWritesTheSwapAreaHeader() throws {
        let pageSize = 4096
        let pages: UInt64 = 32
        let path = try makeArea(pages: pages, pageSize: pageSize)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try Swap.format(path: path, size: pages * UInt64(pageSize), pageSize: pageSize)

        let header = try Data(contentsOf: URL(fileURLWithPath: path))[0..<pageSize]
        #expect(header[1024..<1028] == Data([1, 0, 0, 0]))
        #expect(header[1028..<1032] == Data([UInt8(pages - 1), 0, 0, 0]))
        #expect(String(decoding: header[(pageSize - 10)..<pageSize], as: UTF8.self) == "SWAPSPACE2")
    }

    /// A swap area needs a header page and at least one usable page.
    @Test func formatRejectsAnAreaSmallerThanTwoPages() throws {
        let path = try makeArea(pages: 1, pageSize: 4096)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: (any Error).self) {
            try Swap.format(path: path, size: 4096, pageSize: 4096)
        }
    }

    /// The size of the area is what the device reports, which is how the agent
    /// learns it: the host says how large to make the device, not the guest.
    @Test func sizeReportsTheAreaSize() throws {
        let pageSize = 4096
        let pages: UInt64 = 8
        let path = try makeArea(pages: pages, pageSize: pageSize)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(try Swap.size(ofDeviceAt: path) == pages * UInt64(pageSize))
    }
}
#endif
