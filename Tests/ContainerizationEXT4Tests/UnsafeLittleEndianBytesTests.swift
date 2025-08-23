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

@testable import ContainerizationEXT4

struct UnsafeLittleEndianBytesTests {

    // MARK: - withUnsafeLittleEndianBytes Tests

    @Test func withUnsafeLittleEndianBytesPreservesValue() throws {
        let value: UInt32 = 0x1234_5678

        let result = withUnsafeLittleEndianBytes(of: value) { buffer in
            buffer.count
        }

        #expect(result == MemoryLayout<UInt32>.size)
    }

    @Test func withUnsafeLittleEndianBytesHandlesEndianness() throws {
        let value: UInt16 = 0x1234

        withUnsafeLittleEndianBytes(of: value) { buffer in
            // On little-endian systems, first byte should be 0x34
            // On big-endian systems, conversion should ensure little-endian byte order
            let bytes = Array(buffer)
            #expect(bytes.count == 2)

            // Verify the buffer contains the value in little-endian format
            let reconstructed = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            #expect(reconstructed == value)
        }
    }

    @Test func withUnsafeLittleEndianBytesThrowingClosure() throws {
        struct TestError: Error {}
        let value: UInt8 = 42

        do {
            try withUnsafeLittleEndianBytes(of: value) { _ in
                throw TestError()
            }
            #expect(Bool(false), "Should have thrown TestError")
        } catch is TestError {
            // Expected
        }
    }

    // MARK: - withUnsafeLittleEndianBuffer Tests

    @Test func withUnsafeLittleEndianBufferPreservesData() throws {
        let data = Data([0x12, 0x34, 0x56, 0x78])

        let result = data.withUnsafeBytes { originalBuffer in
            withUnsafeLittleEndianBuffer(of: originalBuffer) { buffer in
                Array(buffer)
            }
        }

        // Result should contain the same data, potentially byte-reversed depending on endianness
        #expect(result.count == 4)
    }

    @Test func withUnsafeLittleEndianBufferHandlesEmptyBuffer() throws {
        let emptyData = Data()

        let result = emptyData.withUnsafeBytes { originalBuffer in
            withUnsafeLittleEndianBuffer(of: originalBuffer) { buffer in
                buffer.count
            }
        }

        #expect(result == 0)
    }

    // MARK: - UnsafeRawBufferPointer.loadLittleEndian Tests

    @Test func loadLittleEndianReturnsCorrectValue() throws {
        let value: UInt32 = 0x1234_5678
        let data = withUnsafeBytes(of: value.littleEndian) { Data($0) }

        let loaded = data.withUnsafeBytes { buffer in
            buffer.loadLittleEndian(as: UInt32.self)
        }

        #expect(loaded == value)
    }

    @Test func loadLittleEndianHandlesDifferentTypes() throws {
        let uint16Value: UInt16 = 0x1234
        let uint16Data = withUnsafeBytes(of: uint16Value.littleEndian) { Data($0) }

        let loadedUInt16 = uint16Data.withUnsafeBytes { buffer in
            buffer.loadLittleEndian(as: UInt16.self)
        }

        #expect(loadedUInt16 == uint16Value)

        let uint64Value: UInt64 = 0x1234_5678_9ABC_DEF0
        let uint64Data = withUnsafeBytes(of: uint64Value.littleEndian) { Data($0) }

        let loadedUInt64 = uint64Data.withUnsafeBytes { buffer in
            buffer.loadLittleEndian(as: UInt64.self)
        }

        #expect(loadedUInt64 == uint64Value)
    }

    // MARK: - Endianness Detection Tests

    @Test func endianDetectionReturnsValidValue() throws {
        let currentEndian = Endian
        #expect(currentEndian == .little || currentEndian == .big)
    }

    @Test func endianConsistentWithSystemEndianness() throws {
        let systemIsLittleEndian = CFByteOrderGetCurrent() == CFByteOrder(CFByteOrderLittleEndian.rawValue)
        let detectedEndian = Endian

        if systemIsLittleEndian {
            #expect(detectedEndian == .little)
        } else {
            #expect(detectedEndian == .big)
        }
    }

    // MARK: - Round-trip Conversion Tests

    @Test func roundTripConversionPreservesData() throws {
        let originalValue: UInt32 = 0xDEAD_BEEF

        let result = withUnsafeLittleEndianBytes(of: originalValue) { buffer in
            buffer.loadLittleEndian(as: UInt32.self)
        }

        #expect(result == originalValue)
    }

    @Test func roundTripWithBufferConversion() throws {
        let originalData = Data([0xFF, 0xEE, 0xDD, 0xCC])

        let result = originalData.withUnsafeBytes { originalBuffer in
            withUnsafeLittleEndianBuffer(of: originalBuffer) { convertedBuffer in
                Data(convertedBuffer)
            }
        }

        // The result should be equivalent to the original when interpreted as little-endian
        let originalAsLittleEndian = originalData.withUnsafeBytes { buffer in
            buffer.loadLittleEndian(as: UInt32.self)
        }

        let resultAsLittleEndian = result.withUnsafeBytes { buffer in
            buffer.loadLittleEndian(as: UInt32.self)
        }

        #expect(originalAsLittleEndian == resultAsLittleEndian)
    }
}
