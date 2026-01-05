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

import Testing

struct BufferTest {
    @Test func testBufferBind() throws {
        let expectedValue: UInt64 = 0x0102_0304_0506_0708
        let expectedBuffer: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        ]
        var buffer = [UInt8](repeating: 0, count: 3 * MemoryLayout<UInt64>.size)
        guard let ptr = buffer.bind(as: UInt64.self, offset: 2 * MemoryLayout<UInt64>.size) else {
            // NOTE: This does not work:
            // let ptr: UnsafeMutablePointer<UInt64> = #require(buffer.bind(as: UInt64.self, offset: MemoryLayout<UInt64>.size), "could not bind value to buffer")
            // it fails with the error:
            // cannot use mutating member on immutable value: '$0' is immutable
            //   $0.bind(as: $1, offset: $2)
            #expect(Bool(false), "could not bind value to buffer")
            return
        }

        ptr.pointee = expectedValue
        #expect(buffer == expectedBuffer)
    }

    @Test func testBufferBindRangeError() throws {
        var buffer = [UInt8](repeating: 0, count: 3 * MemoryLayout<UInt64>.size)
        #expect(buffer.bind(as: UInt64.self, offset: 2 * MemoryLayout<UInt64>.size + 1) == nil)
    }

    @Test func testBufferCopy() throws {
        let inputBuffer: [UInt8] = [0x01, 0x02, 0x03]
        var buffer = [UInt8](repeating: 0, count: 9)

        guard let offset = buffer.copyIn(buffer: inputBuffer, offset: 4) else {
            #expect(Bool(false), "could not copy to buffer")
            return
        }
        #expect(offset == 7)

        guard let offset = buffer.copyIn(buffer: inputBuffer, offset: 6) else {
            #expect(Bool(false), "could not copy to buffer")
            return
        }
        #expect(offset == 9)

        let expectedBuffer: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x02, 0x03,
        ]
        #expect(expectedBuffer == buffer)

        var outputBuffer = [UInt8](repeating: 0, count: 3)
        guard let offset = buffer.copyOut(buffer: &outputBuffer, offset: 6) else {
            #expect(Bool(false), "could not copy to buffer")
            return
        }
        #expect(offset == 9)

        let expectedOutputBuffer: [UInt8] = [
            0x01, 0x02, 0x03,
        ]
        #expect(expectedOutputBuffer == outputBuffer)
    }

    @Test func testBufferCopyRangeError() throws {
        let inputBuffer: [UInt8] = [0x01, 0x02, 0x03]
        var buffer = [UInt8](repeating: 0, count: 9)

        #expect(buffer.copyIn(buffer: inputBuffer, offset: 7) == nil)

        var outputBuffer = [UInt8](repeating: 0, count: 3)
        #expect(buffer.copyOut(buffer: &outputBuffer, offset: 7) == nil)
    }
}
