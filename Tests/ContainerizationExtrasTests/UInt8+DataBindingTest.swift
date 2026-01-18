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
@testable import ContainerizationExtras

struct BufferTest {
    // MARK: - hexEncodedString Tests

    @Test func testArrayHexEncodedStringEmpty() {
        let buffer: [UInt8] = []
        #expect(buffer.hexEncodedString() == "")
    }

    @Test func testArrayHexEncodedStringSingleByte() {
        let buffer: [UInt8] = [0xFF]
        #expect(buffer.hexEncodedString() == "ff")
    }

    @Test func testArrayHexEncodedStringMultipleBytes() {
        let buffer: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
        #expect(buffer.hexEncodedString() == "0123456789abcdef")
    }

    @Test func testArrayHexEncodedStringZeroes() {
        let buffer: [UInt8] = [0x00, 0x00, 0x00]
        #expect(buffer.hexEncodedString() == "000000")
    }

    @Test func testArraySliceHexEncodedStringEmpty() {
        let buffer: [UInt8] = [0x01, 0x02, 0x03]
        let slice = buffer[0..<0]
        #expect(slice.hexEncodedString() == "")
    }

    @Test func testArraySliceHexEncodedStringSingleByte() {
        let buffer: [UInt8] = [0x01, 0x02, 0x03]
        let slice = buffer[1..<2]
        #expect(slice.hexEncodedString() == "02")
    }

    @Test func testArraySliceHexEncodedStringMultipleBytes() {
        let buffer: [UInt8] = [0x00, 0xAA, 0xBB, 0xCC, 0x00]
        let slice = buffer[1..<4]
        #expect(slice.hexEncodedString() == "aabbcc")
    }

    // MARK: - bind<T> Tests

    @Test func testBufferBind() throws {
        let expectedValue: UInt64 = 0x0102_0304_0506_0708
        let expectedBuffer: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        ]
        var buffer = [UInt8](repeating: 0, count: 3 * MemoryLayout<UInt64>.size)
        guard let ptr = buffer.bind(as: UInt64.self, offset: 2 * MemoryLayout<UInt64>.size) else {
            #expect(Bool(false), "could not bind value to buffer")
            return
        }

        ptr.pointee = expectedValue
        #expect(buffer == expectedBuffer)
    }

    @Test func testBufferBindZeroOffset() {
        let expectedValue: UInt32 = 0x12345678
        var buffer = [UInt8](repeating: 0, count: 8)
        guard let ptr = buffer.bind(as: UInt32.self, offset: 0) else {
            #expect(Bool(false), "could not bind value to buffer at offset 0")
            return
        }

        ptr.pointee = expectedValue
        #expect(buffer[0] == 0x78)
        #expect(buffer[1] == 0x56)
        #expect(buffer[2] == 0x34)
        #expect(buffer[3] == 0x12)
    }

    @Test func testBufferBindRangeError() throws {
        var buffer = [UInt8](repeating: 0, count: 3 * MemoryLayout<UInt64>.size)
        #expect(buffer.bind(as: UInt64.self, offset: 2 * MemoryLayout<UInt64>.size + 1) == nil)
    }

    @Test func testBufferBindRangeErrorExactBoundary() {
        var buffer = [UInt8](repeating: 0, count: 8)
        // Trying to bind UInt64 at offset 1 requires 9 bytes total
        #expect(buffer.bind(as: UInt64.self, offset: 1) == nil)
    }

    @Test func testBufferBindWithCustomSize() {
        var buffer = [UInt8](repeating: 0, count: 16)
        // Request a size larger than the type
        guard let ptr = buffer.bind(as: UInt32.self, offset: 4, size: 8) else {
            #expect(Bool(false), "could not bind with custom size")
            return
        }

        ptr.pointee = 0xAABBCCDD
        #expect(buffer[4] == 0xDD)
        #expect(buffer[5] == 0xCC)
        #expect(buffer[6] == 0xBB)
        #expect(buffer[7] == 0xAA)
    }

    @Test func testBufferBindWithCustomSizeRangeError() {
        var buffer = [UInt8](repeating: 0, count: 10)
        // Request size 8 at offset 4 would require 12 bytes total
        #expect(buffer.bind(as: UInt32.self, offset: 4, size: 8) == nil)
    }

    // MARK: - copyIn<T> Tests

    @Test func testCopyInUInt8() {
        var buffer = [UInt8](repeating: 0, count: 4)
        let value: UInt8 = 0x42

        guard let offset = buffer.copyIn(as: UInt8.self, value: value, offset: 2) else {
            #expect(Bool(false), "could not copy UInt8 to buffer")
            return
        }

        #expect(offset == 3)
        #expect(buffer[2] == 0x42)
    }

    @Test func testCopyInUInt16() {
        var buffer = [UInt8](repeating: 0, count: 8)
        let value: UInt16 = 0x1234

        guard let offset = buffer.copyIn(as: UInt16.self, value: value, offset: 3) else {
            #expect(Bool(false), "could not copy UInt16 to buffer")
            return
        }

        #expect(offset == 5)
        #expect(buffer[3] == 0x34)
        #expect(buffer[4] == 0x12)
    }

    @Test func testCopyInUInt32() {
        var buffer = [UInt8](repeating: 0, count: 8)
        let value: UInt32 = 0x12345678

        guard let offset = buffer.copyIn(as: UInt32.self, value: value, offset: 0) else {
            #expect(Bool(false), "could not copy UInt32 to buffer")
            return
        }

        #expect(offset == 4)
        #expect(buffer[0] == 0x78)
        #expect(buffer[1] == 0x56)
        #expect(buffer[2] == 0x34)
        #expect(buffer[3] == 0x12)
    }

    @Test func testCopyInUInt64() {
        var buffer = [UInt8](repeating: 0, count: 16)
        let value: UInt64 = 0x0102030405060708

        guard let offset = buffer.copyIn(as: UInt64.self, value: value, offset: 4) else {
            #expect(Bool(false), "could not copy UInt64 to buffer")
            return
        }

        #expect(offset == 12)
        #expect(buffer[4] == 0x08)
        #expect(buffer[5] == 0x07)
        #expect(buffer[6] == 0x06)
        #expect(buffer[7] == 0x05)
        #expect(buffer[8] == 0x04)
        #expect(buffer[9] == 0x03)
        #expect(buffer[10] == 0x02)
        #expect(buffer[11] == 0x01)
    }

    @Test func testCopyInRangeError() {
        var buffer = [UInt8](repeating: 0, count: 8)
        let value: UInt64 = 0x1234567890ABCDEF

        // Offset 4 + size 8 = 12, but buffer only has 8 bytes
        #expect(buffer.copyIn(as: UInt64.self, value: value, offset: 4) == nil)
    }

    @Test func testCopyInExactBoundary() {
        var buffer = [UInt8](repeating: 0, count: 8)
        let value: UInt64 = 0xFEDCBA9876543210

        guard let offset = buffer.copyIn(as: UInt64.self, value: value, offset: 0) else {
            #expect(Bool(false), "could not copy UInt64 at exact boundary")
            return
        }

        #expect(offset == 8)
    }

    @Test func testCopyInWithCustomSize() {
        var buffer = [UInt8](repeating: 0, count: 16)
        let value: UInt32 = 0xAABBCCDD

        // Copy with custom size of 8 (larger than UInt32's 4 bytes)
        guard let offset = buffer.copyIn(as: UInt32.self, value: value, offset: 2, size: 8) else {
            #expect(Bool(false), "could not copy with custom size")
            return
        }

        #expect(offset == 6)  // offset + MemoryLayout<UInt32>.size
        #expect(buffer[2] == 0xDD)
        #expect(buffer[3] == 0xCC)
        #expect(buffer[4] == 0xBB)
        #expect(buffer[5] == 0xAA)
    }

    @Test func testCopyInWithCustomSizeRangeError() {
        var buffer = [UInt8](repeating: 0, count: 8)
        let value: UInt32 = 0x12345678

        // Request size 8 at offset 2 would require 10 bytes total
        #expect(buffer.copyIn(as: UInt32.self, value: value, offset: 2, size: 8) == nil)
    }

    // MARK: - copyOut<T> Tests

    @Test func testCopyOutUInt8() {
        var buffer: [UInt8] = [0x00, 0x11, 0x22, 0x33]

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: 2) else {
            #expect(Bool(false), "could not copy out UInt8")
            return
        }

        #expect(offset == 3)
        #expect(value == 0x22)
    }

    @Test func testCopyOutUInt16() {
        var buffer: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: 2) else {
            #expect(Bool(false), "could not copy out UInt16")
            return
        }

        #expect(offset == 4)
        #expect(value == 0x3322)
    }

    @Test func testCopyOutUInt32() {
        var buffer: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: 0) else {
            #expect(Bool(false), "could not copy out UInt32")
            return
        }

        #expect(offset == 4)
        #expect(value == 0x78563412)
    }

    @Test func testCopyOutUInt64() {
        var buffer: [UInt8] = [
            0x00, 0x00, 0x00, 0x00,
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
            0xFF, 0xFF
        ]

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: 4) else {
            #expect(Bool(false), "could not copy out UInt64")
            return
        }

        #expect(offset == 12)
        #expect(value == 0x8877665544332211)
    }

    @Test func testCopyOutRangeError() {
        var buffer: [UInt8] = [0x00, 0x11, 0x22, 0x33]

        // Trying to read UInt64 from offset 0 with only 4 bytes
        #expect(buffer.copyOut(as: UInt64.self, offset: 0) == nil)
    }

    @Test func testCopyOutExactBoundary() {
        var buffer: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: 0) else {
            #expect(Bool(false), "could not copy out at exact boundary")
            return
        }

        #expect(offset == 8)
        #expect(value == 0x0807060504030201)
    }

    @Test func testCopyOutWithCustomSize() {
        var buffer: [UInt8] = [0x00, 0x00, 0x11, 0x22, 0x33, 0x44, 0xFF, 0xFF, 0xFF, 0xFF]

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: 2, size: 8) else {
            #expect(Bool(false), "could not copy out with custom size")
            return
        }

        #expect(offset == 6)  // offset + MemoryLayout<UInt32>.size
        #expect(value == 0x44332211)
    }

    @Test func testCopyOutWithCustomSizeRangeError() {
        var buffer: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]

        // Request size 8 at offset 2 would require 10 bytes total, but buffer only has 6
        #expect(buffer.copyOut(as: UInt32.self, offset: 2, size: 8) == nil)
    }

    // MARK: - copyIn(buffer:) and copyOut(buffer:) Tests

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

    @Test func testBufferCopyZeroOffset() {
        let inputBuffer: [UInt8] = [0xAA, 0xBB, 0xCC]
        var buffer = [UInt8](repeating: 0, count: 5)

        guard let offset = buffer.copyIn(buffer: inputBuffer, offset: 0) else {
            #expect(Bool(false), "could not copy to buffer at offset 0")
            return
        }

        #expect(offset == 3)
        #expect(buffer[0] == 0xAA)
        #expect(buffer[1] == 0xBB)
        #expect(buffer[2] == 0xCC)
    }

    @Test func testBufferCopyEmptyBuffer() {
        let inputBuffer: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 5)

        guard let offset = buffer.copyIn(buffer: inputBuffer, offset: 2) else {
            #expect(Bool(false), "could not copy empty buffer")
            return
        }

        #expect(offset == 2)
    }

    @Test func testBufferCopyExactFit() {
        let inputBuffer: [UInt8] = [0x01, 0x02, 0x03]
        var buffer = [UInt8](repeating: 0, count: 6)

        guard let offset = buffer.copyIn(buffer: inputBuffer, offset: 3) else {
            #expect(Bool(false), "could not copy to exact fit")
            return
        }

        #expect(offset == 6)
    }

    @Test func testBufferCopyRangeError() throws {
        let inputBuffer: [UInt8] = [0x01, 0x02, 0x03]
        var buffer = [UInt8](repeating: 0, count: 9)

        #expect(buffer.copyIn(buffer: inputBuffer, offset: 7) == nil)

        var outputBuffer = [UInt8](repeating: 0, count: 3)
        #expect(buffer.copyOut(buffer: &outputBuffer, offset: 7) == nil)
    }

    @Test func testBufferCopyOutZeroOffset() {
        var buffer: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55]
        var outputBuffer = [UInt8](repeating: 0, count: 3)

        guard let offset = buffer.copyOut(buffer: &outputBuffer, offset: 0) else {
            #expect(Bool(false), "could not copy out at offset 0")
            return
        }

        #expect(offset == 3)
        #expect(outputBuffer[0] == 0x11)
        #expect(outputBuffer[1] == 0x22)
        #expect(outputBuffer[2] == 0x33)
    }

    @Test func testBufferCopyOutEmptyBuffer() {
        var buffer: [UInt8] = [0x11, 0x22, 0x33]
        var outputBuffer: [UInt8] = []

        guard let offset = buffer.copyOut(buffer: &outputBuffer, offset: 1) else {
            #expect(Bool(false), "could not copy out to empty buffer")
            return
        }

        #expect(offset == 1)
    }

    @Test func testBufferCopyOutExactFit() {
        var buffer: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        var outputBuffer = [UInt8](repeating: 0, count: 3)

        guard let offset = buffer.copyOut(buffer: &outputBuffer, offset: 3) else {
            #expect(Bool(false), "could not copy out exact fit")
            return
        }

        #expect(offset == 6)
        #expect(outputBuffer[0] == 0xDD)
        #expect(outputBuffer[1] == 0xEE)
        #expect(outputBuffer[2] == 0xFF)
    }
}
