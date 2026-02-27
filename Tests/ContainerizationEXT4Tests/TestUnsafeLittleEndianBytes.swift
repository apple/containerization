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

struct TestUnsafeLittleEndianBytes {
    @Test func testWithUnsafeLittleEndianBytes() {
        let value: UInt32 = 0x1234_5678

        let result = withUnsafeLittleEndianBytes(of: value) { bytes in
            bytes.count
        }

        #expect(result == MemoryLayout<UInt32>.size)
    }

    @Test func testWithUnsafeLittleEndianBytesThrows() {
        let value: UInt16 = 0x1234

        do {
            let _ = try withUnsafeLittleEndianBytes(of: value) { bytes -> Int in
                throw NSError(domain: "TestError", code: 1)
            }
            #expect(Bool(false), "Should have thrown an error")
        } catch {
            #expect(error.localizedDescription.contains("TestError"))
        }
    }

    @Test func testWithUnsafeLittleEndianBuffer() {
        let data: [UInt8] = [0x78, 0x56, 0x34, 0x12]
        let result = data.withUnsafeBytes { buffer in
            withUnsafeLittleEndianBuffer(of: buffer) { buf in
                buf.count
            }
        }

        #expect(result == 4)
    }

    @Test func testWithUnsafeLittleEndianBufferThrows() {
        let data: [UInt8] = [0x12, 0x34]

        do {
            let _ = try data.withUnsafeBytes { buffer in
                try withUnsafeLittleEndianBuffer(of: buffer) { buf -> Int in
                    throw NSError(domain: "TestError", code: 1)
                }
            }
            #expect(Bool(false), "Should have thrown an error")
        } catch {
            #expect(error.localizedDescription.contains("TestError"))
        }
    }

    @Test func testUnsafeRawBufferPointerLoadLittleEndian() {
        let value: UInt32 = 0x1234_5678
        let data: [UInt8] = [0x78, 0x56, 0x34, 0x12]  // Little endian representation

        let result = data.withUnsafeBytes { buffer in
            buffer.loadLittleEndian(as: UInt32.self)
        }

        #expect(result == value)
    }

    @Test func testUnsafeRawBufferPointerLoadLittleEndianDifferentTypes() {
        let data16: [UInt8] = [0x34, 0x12]  // Little endian 0x1234
        let result16 = data16.withUnsafeBytes { buffer in
            buffer.loadLittleEndian(as: UInt16.self)
        }
        #expect(result16 == 0x1234)

        let data64: [UInt8] = [0x78, 0x56, 0x34, 0x12, 0xBC, 0x9A, 0x78, 0x56]  // Little endian
        let result64 = data64.withUnsafeBytes { buffer in
            buffer.loadLittleEndian(as: UInt64.self)
        }
        #expect(result64 == 0x5678_9ABC_1234_5678)
    }

    @Test func testEndianness() {
        let currentEndian = Endian
        #expect(currentEndian == .little || currentEndian == .big)

        // On Apple Silicon and Intel Macs, we expect little endian
        #expect(currentEndian == .little)
    }

    @Test func testEndiannessConsistency() {
        // Test that our endianness detection is consistent
        let endian1 = Endian
        let endian2 = Endian
        #expect(endian1 == endian2)
    }

    @Test func testWithUnsafeLittleEndianBytesLittleEndian() {
        // Test behavior specifically on little endian systems
        let value: UInt32 = 0x1234_5678
        let expected: [UInt8] = [0x78, 0x56, 0x34, 0x12]

        let result = withUnsafeLittleEndianBytes(of: value) { bytes in
            Array(bytes)
        }

        if Endian == .little {
            #expect(result == expected)
        } else {
            #expect(result == expected.reversed())
        }
    }
}
