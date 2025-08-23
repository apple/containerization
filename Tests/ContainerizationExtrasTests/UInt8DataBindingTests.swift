//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

@testable import ContainerizationExtras

struct UInt8DataBindingTests {

    // MARK: - ArraySlice hexEncodedString Tests

    @Test func arraySliceHexEncodingEmptySlice() throws {
        let emptySlice: ArraySlice<UInt8> = []
        let result = emptySlice.hexEncodedString()

        #expect(result == "")
    }

    @Test func arraySliceHexEncodingSingleByte() throws {
        let slice: ArraySlice<UInt8> = [255]
        let result = slice.hexEncodedString()

        #expect(result == "ff")
    }

    @Test func arraySliceHexEncodingMultipleBytes() throws {
        let slice: ArraySlice<UInt8> = [0x00, 0x0f, 0xa5, 0xff]
        let result = slice.hexEncodedString()

        #expect(result == "000fa5ff")
    }

    // MARK: - Array hexEncodedString Tests

    @Test func arrayHexEncodingEmptyArray() throws {
        let emptyArray: [UInt8] = []
        let result = emptyArray.hexEncodedString()

        #expect(result == "")
    }

    @Test func arrayHexEncodingSingleByte() throws {
        let array: [UInt8] = [171]  // 0xab
        let result = array.hexEncodedString()

        #expect(result == "ab")
    }

    @Test func arrayHexEncodingStandardBytes() throws {
        let array: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
        let result = array.hexEncodedString()

        #expect(result == "deadbeef")
    }

    @Test func arrayHexEncodingLeadingZeros() throws {
        let array: [UInt8] = [0x00, 0x01, 0x0a, 0x10]
        let result = array.hexEncodedString()

        #expect(result == "00010a10")
    }

    // MARK: - bind Tests

    @Test func bindReturnsPointerForValidData() throws {
        var data: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        let pointer = data.bind(as: UInt32.self)

        #expect(pointer != nil)
    }

    @Test func bindReturnsNilForInsufficientData() throws {
        var data: [UInt8] = [0x12, 0x34]  // Only 2 bytes
        let pointer = data.bind(as: UInt32.self)  // Needs 4 bytes

        #expect(pointer == nil)
    }

    @Test func bindWithOffsetAndSize() throws {
        var data: [UInt8] = [0x00, 0x00, 0x12, 0x34, 0x56, 0x78]
        let pointer = data.bind(as: UInt16.self, offset: 2, size: 2)

        #expect(pointer != nil)
    }

    @Test func bindWithInvalidOffset() throws {
        var data: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        let pointer = data.bind(as: UInt32.self, offset: 2)  // Not enough space after offset

        #expect(pointer == nil)
    }

    // MARK: - copyIn Tests

    @Test func copyInSucceedsWithValidData() throws {
        var data: [UInt8] = [0x00, 0x00, 0x00, 0x00]
        let value: UInt32 = 0x1234_5678
        let result = data.copyIn(as: UInt32.self, value: value)

        #expect(result != nil)
        #expect(result == 4)  // Should return offset + size
    }

    @Test func copyInFailsWithInsufficientSpace() throws {
        var data: [UInt8] = [0x00, 0x00]  // Only 2 bytes
        let value: UInt32 = 0x1234_5678
        let result = data.copyIn(as: UInt32.self, value: value)

        #expect(result == nil)
    }

    @Test func copyInWithOffset() throws {
        var data: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let value: UInt16 = 0x1234
        let result = data.copyIn(as: UInt16.self, value: value, offset: 2)

        #expect(result != nil)
        #expect(result == 4)  // offset(2) + size(2)
    }

    // MARK: - copyOut Tests

    @Test func copyOutSucceedsWithValidData() throws {
        var data: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        let result = data.copyOut(as: UInt32.self)

        #expect(result != nil)
        #expect(result?.0 == 4)  // New offset
    }

    @Test func copyOutFailsWithInsufficientData() throws {
        var data: [UInt8] = [0x12, 0x34]  // Only 2 bytes
        let result = data.copyOut(as: UInt32.self)  // Needs 4 bytes

        #expect(result == nil)
    }

    @Test func copyOutWithOffset() throws {
        var data: [UInt8] = [0x00, 0x00, 0x12, 0x34]
        let result = data.copyOut(as: UInt16.self, offset: 2)

        #expect(result != nil)
        #expect(result?.0 == 4)  // offset(2) + size(2)
    }

    // MARK: - copyIn buffer Tests

    @Test func copyInBufferSucceedsWithValidSpace() throws {
        var data: [UInt8] = [0x00, 0x00, 0x00, 0x00]
        let buffer: [UInt8] = [0xaa, 0xbb]
        let result = data.copyIn(buffer: buffer, offset: 1)

        #expect(result != nil)
        #expect(result == 3)  // offset(1) + buffer.count(2)
        #expect(data[1] == 0xaa)
        #expect(data[2] == 0xbb)
    }

    @Test func copyInBufferFailsWithInsufficientSpace() throws {
        var data: [UInt8] = [0x00, 0x00]
        let buffer: [UInt8] = [0xaa, 0xbb, 0xcc]
        let result = data.copyIn(buffer: buffer, offset: 0)

        #expect(result == nil)
    }

    @Test func copyInBufferWithOffset() throws {
        var data: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00]
        let buffer: [UInt8] = [0x11, 0x22]
        let result = data.copyIn(buffer: buffer, offset: 2)

        #expect(result != nil)
        #expect(result == 4)
        #expect(data[2] == 0x11)
        #expect(data[3] == 0x22)
    }

    // MARK: - copyOut buffer Tests

    @Test func copyOutBufferSucceedsWithValidData() throws {
        var data: [UInt8] = [0xaa, 0xbb, 0xcc, 0xdd]
        var buffer: [UInt8] = [0x00, 0x00]
        let result = data.copyOut(buffer: &buffer, offset: 1)

        #expect(result != nil)
        #expect(result == 3)  // offset(1) + buffer.count(2)
        #expect(buffer[0] == 0xbb)
        #expect(buffer[1] == 0xcc)
    }

    @Test func copyOutBufferFailsWithInsufficientData() throws {
        var data: [UInt8] = [0xaa, 0xbb]
        var buffer: [UInt8] = [0x00, 0x00, 0x00]
        let result = data.copyOut(buffer: &buffer, offset: 0)

        #expect(result == nil)
    }

    @Test func copyOutBufferWithOffset() throws {
        var data: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55]
        var buffer: [UInt8] = [0x00, 0x00]
        let result = data.copyOut(buffer: &buffer, offset: 2)

        #expect(result != nil)
        #expect(result == 4)
        #expect(buffer[0] == 0x33)
        #expect(buffer[1] == 0x44)
    }

    // MARK: - Integration Tests

    @Test func roundTripDataBindingIntegration() throws {
        var data: [UInt8] = Array(repeating: 0, count: 8)
        let originalValue: UInt64 = 0x1234_5678_9ABC_DEF0

        // Copy in the value
        let copyInResult = data.copyIn(as: UInt64.self, value: originalValue)
        #expect(copyInResult == 8)

        // Copy out the value
        let copyOutResult = data.copyOut(as: UInt64.self)
        #expect(copyOutResult != nil)
        #expect(copyOutResult?.1 == originalValue)
    }

    @Test func hexEncodingRoundTripConsistency() throws {
        let originalBytes: [UInt8] = [0x00, 0x0f, 0xa5, 0xff, 0xde, 0xad, 0xbe, 0xef]
        let hexString = originalBytes.hexEncodedString()

        #expect(hexString == "000fa5ffdeadbeef")

        // Convert back using Foundation for verification
        let reconstructed = Data(hex: hexString)
        #expect(Array(reconstructed) == originalBytes)
    }
}

// Helper extension for hex conversion verification
extension Data {
    init(hex: String) {
        self.init()
        var hexString = hex
        if hexString.count % 2 != 0 {
            hexString = "0" + hexString
        }

        for i in stride(from: 0, to: hexString.count, by: 2) {
            let start = hexString.index(hexString.startIndex, offsetBy: i)
            let end = hexString.index(start, offsetBy: 2)
            let byteString = String(hexString[start..<end])
            if let byte = UInt8(byteString, radix: 16) {
                self.append(byte)
            }
        }
    }
}
