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

import Foundation
import Testing

@testable import ContainerizationExtras

@Suite("IPv6 Mixed IPv4 Notation Tests")
struct IPv6IPv4ParsingTests {

    @Test(
        "Extract IPv4 suffix from various IPv6 formats",
        arguments: [
            ("::192.168.1.1", "::", [UInt8(192), UInt8(168), UInt8(1), UInt8(1)]),
            ("::ffff:192.0.2.1", "::ffff", [UInt8(192), UInt8(0), UInt8(2), UInt8(1)]),
            ("fe80::192.168.1.1", "fe80::", [UInt8(192), UInt8(168), UInt8(1), UInt8(1)]),
            ("2001:db8::192.0.2.1", "2001:db8::", [UInt8(192), UInt8(0), UInt8(2), UInt8(1)]),
            ("0:0:0:0:0:0:192.168.1.1", "0:0:0:0:0:0", [UInt8(192), UInt8(168), UInt8(1), UInt8(1)]),
        ]
    )
    func testIPv4SuffixExtraction(input: String, expectedIPv6: String, expectedIPv4: [UInt8]) throws {
        let result = try #require(try IPv6Address.extractIPv4Suffix(from: input))
        #expect(result.0 == expectedIPv6)
        #expect(result.1 == expectedIPv4)
    }

    @Test(
        "No IPv4 suffix for pure IPv6 addresses",
        arguments: [
            "2001:db8::1",
            "fe80::1",
            "::",
            "::1",
        ]
    )
    func testPureIPv6ReturnsNil(address: String) throws {
        #expect(try IPv6Address.extractIPv4Suffix(from: address) == nil)
    }

    @Test(
        "Invalid IPv4 suffix throws error",
        arguments: [
            "::256.1.1.1",
            "::192.168.1",
            "::192.168.001.1",
        ]
    )
    func testInvalidIPv4Throws(invalid: String) {
        #expect(throws: AddressError.self) {
            _ = try IPv6Address.extractIPv4Suffix(from: invalid)
        }
    }

    @Test(
        "IPv4 bytes always at positions 12-15",
        arguments: [
            "::192.168.1.1",
            "::ffff:127.0.0.1",
            "fe80::10.0.0.1",
        ]
    )
    func testIPv4BytePlacement(address: String) throws {
        let parsed = try IPv6Address.parse(address)
        let ipv4String = String(address.split(separator: ":").last!)
        let ipv4 = try IPv4Address.parse(ipv4String)

        #expect(parsed.bytes[12] == UInt8((ipv4 >> 24) & 0xFF))
        #expect(parsed.bytes[13] == UInt8((ipv4 >> 16) & 0xFF))
        #expect(parsed.bytes[14] == UInt8((ipv4 >> 8) & 0xFF))
        #expect(parsed.bytes[15] == UInt8(ipv4 & 0xFF))
    }

    @Test(
        "Unspecified address with IPv4 suffix",
        arguments: [
            ("::192.168.1.1", [UInt8(192), UInt8(168), UInt8(1), UInt8(1)]),
            ("::0.0.0.1", [UInt8(0), UInt8(0), UInt8(0), UInt8(1)]),
            ("::255.255.255.255", [UInt8(255), UInt8(255), UInt8(255), UInt8(255)]),
        ]
    )
    func testUnspecifiedWithIPv4(address: String, ipv4: [UInt8]) throws {
        let parsed = try IPv6Address.parse(address)
        #expect(parsed.bytes[0..<12].allSatisfy { $0 == 0 })
        #expect(Array(parsed.bytes[12..<16]) == ipv4)
    }

    @Test("IPv4 with zone identifier")
    func testIPv4WithZone() throws {
        let parsed = try IPv6Address.parse("::192.168.1.1%lo0")

        #expect(parsed.zone == "lo0")
        #expect(Array(parsed.bytes[12..<16]) == [192, 168, 1, 1])
    }

    @Test(
        "IPv4-mapped addresses (::ffff:x.x.x.x)",
        arguments: [
            "::ffff:127.0.0.1",
            "::ffff:192.168.1.1",
        ]
    )
    func testIPv4MappedAddresses(address: String) throws {
        let parsed = try IPv6Address.parse(address)

        #expect(parsed.bytes[0..<10].allSatisfy { $0 == 0 })
        #expect(parsed.bytes[10] == 0xff && parsed.bytes[11] == 0xff)
    }

    @Test("Complex ellipsis with IPv4")
    func testComplexEllipsisWithIPv4() throws {
        let address = "2001:db8:85a3::8a2e:192.168.1.1"
        let parsed = try IPv6Address.parse(address)

        #expect(parsed.bytes[10] == 0x8a && parsed.bytes[11] == 0x2e)
        #expect(Array(parsed.bytes[12..<16]) == [192, 168, 1, 1])
    }
}
