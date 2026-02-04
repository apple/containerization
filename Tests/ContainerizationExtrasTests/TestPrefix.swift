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

struct TestPrefix {

    // MARK: - IPv4 Mask Tests

    struct IPv4Mask {
        let length: UInt8
        let expectedPrefix: UInt32
        let expectedSuffix: UInt32
    }

    @Test(arguments: [
        IPv4Mask(
            length: 0,
            expectedPrefix: 0x0000_0000,
            expectedSuffix: 0xFFFF_FFFF
        ),
        IPv4Mask(
            length: 8,
            expectedPrefix: 0xFF00_0000,
            expectedSuffix: 0x00FF_FFFF
        ),
        IPv4Mask(
            length: 16,
            expectedPrefix: 0xFFFF_0000,
            expectedSuffix: 0x0000_FFFF
        ),
        IPv4Mask(
            length: 24,
            expectedPrefix: 0xFFFF_FF00,
            expectedSuffix: 0x0000_00FF
        ),
        IPv4Mask(
            length: 32,
            expectedPrefix: 0xFFFF_FFFF,
            expectedSuffix: 0x0000_0000
        ),
    ])
    func testIPv4Masks(testCase: IPv4Mask) {
        let prefix = Prefix(length: testCase.length)!
        #expect(prefix.prefixMask32 == testCase.expectedPrefix)
        #expect(prefix.suffixMask32 == testCase.expectedSuffix)
    }

    @Test func testMasksAreInverses32() {
        for length in 0...32 {
            let prefix = Prefix(length: UInt8(length))!
            #expect(~prefix.prefixMask32 == prefix.suffixMask32)
        }
    }

    // MARK: - IPv6 Mask Tests

    struct IPv6Mask {
        let length: UInt8
        let expectedPrefix: UInt128
        let expectedSuffix: UInt128
    }

    @Test func testIPv6Masks() {
        let cases = [
            IPv6Mask(
                length: 0,
                expectedPrefix: UInt128(0),
                expectedSuffix: UInt128.max
            ),
            IPv6Mask(
                length: 64,
                expectedPrefix: 0xFFFF_FFFF_FFFF_FFFF_0000_0000_0000_0000,
                expectedSuffix: 0x0000_0000_0000_0000_FFFF_FFFF_FFFF_FFFF
            ),
            IPv6Mask(
                length: 128,
                expectedPrefix: UInt128.max,
                expectedSuffix: UInt128(0)
            ),
        ]
        for testCase in cases {
            let prefix = Prefix(length: testCase.length)!
            #expect(prefix.prefixMask128 == testCase.expectedPrefix)
            #expect(prefix.suffixMask128 == testCase.expectedSuffix)
        }
    }

    @Test func testMasksAreInverses128() {
        for length in stride(from: 0, through: 128, by: 8) {
            let prefix = Prefix(length: UInt8(length))!
            #expect(~prefix.prefixMask128 == prefix.suffixMask128)
        }
    }

    // MARK: - Description Tests

    @Test func testDescription() {
        #expect(Prefix(length: 24)!.description == "24")
        #expect(Prefix(length: 0)!.description == "0")
        #expect(Prefix(length: 128)!.description == "128")
    }

    // MARK: - Validation Tests

    @Test func testValidationRejectsInvalidLengths() {
        // Valid ranges
        #expect(Prefix(length: 0) != nil)
        #expect(Prefix(length: 32) != nil)
        #expect(Prefix(length: 128) != nil)

        // Invalid ranges
        #expect(Prefix(length: 129) == nil)
        #expect(Prefix(length: 200) == nil)
        #expect(Prefix(length: 255) == nil)
    }

    @Test func testIPv4SpecificValidation() {
        // Valid IPv4 prefixes
        #expect(Prefix.ipv4(0) != nil)
        #expect(Prefix.ipv4(16) != nil)
        #expect(Prefix.ipv4(32) != nil)

        // Invalid IPv4 prefixes
        #expect(Prefix.ipv4(33) == nil)
        #expect(Prefix.ipv4(64) == nil)
        #expect(Prefix.ipv4(128) == nil)
    }

    @Test func testIPv6SpecificValidation() {
        // Valid IPv6 prefixes
        #expect(Prefix.ipv6(0) != nil)
        #expect(Prefix.ipv6(64) != nil)
        #expect(Prefix.ipv6(128) != nil)

        // Invalid IPv6 prefixes
        #expect(Prefix.ipv6(129) == nil)
        #expect(Prefix.ipv6(255) == nil)
    }
}
