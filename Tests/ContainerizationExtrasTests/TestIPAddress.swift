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

@Suite("Unified IPAddress Tests")
struct IPAddressTests {

    @Test(
        "Parse IPv4 addresses",
        arguments: [
            "192.168.1.1",
            "127.0.0.1",
            "0.0.0.0",
            "255.255.255.255",
        ]
    )
    func testParseIPv4(input: String) throws {
        let ip = try IPAddress(input)
        #expect(ip.isV4, "Should be IPv4: \(input)")
        #expect(!ip.isV6, "Should not be IPv6: \(input)")
        #expect(ip.ipv4 != nil, "Should have IPv4 value: \(input)")
        #expect(ip.ipv6 == nil, "Should not have IPv6 value: \(input)")
    }

    @Test(
        "Parse IPv6 addresses",
        arguments: [
            "2001:db8::1",
            "::1",
            "::",
            "fe80::1",
            "2001:db8:0:0:0:0:0:1",
        ]
    )
    func testParseIPv6(input: String) throws {
        let ip = try IPAddress(input)
        #expect(ip.isV6, "Should be IPv6: \(input)")
        #expect(!ip.isV4, "Should not be IPv4: \(input)")
        #expect(ip.ipv6 != nil, "Should have IPv6 value: \(input)")
        #expect(ip.ipv4 == nil, "Should not have IPv4 value: \(input)")
    }

    @Test(
        "Loopback detection",
        arguments: [
            // Loopback addresses
            ("127.0.0.1", true, "IPv4 loopback"),
            ("127.0.0.255", true, "IPv4 loopback variant"),
            ("127.255.255.255", true, "Any 127.x.x.x"),
            ("::1", true, "IPv6 loopback"),
            // Non-loopback addresses
            ("192.168.1.1", false, "Private IPv4"),
            ("2001:db8::1", false, "IPv6 documentation"),
            ("0.0.0.0", false, "IPv4 unspecified"),
            ("::", false, "IPv6 unspecified"),
        ]
    )
    func testLoopback(input: String, expected: Bool, description: String) throws {
        let ip = try IPAddress(input)
        #expect(ip.isLoopback == expected, "\(description): \(input) should\(expected ? "" : " not") be loopback")
    }

    @Test(
        "Multicast detection",
        arguments: [
            // Multicast addresses
            ("224.0.0.1", true, "IPv4 multicast start"),
            ("239.255.255.255", true, "IPv4 multicast end (224.0.0.0/4)"),
            ("ff02::1", true, "IPv6 link-local multicast"),
            ("ff00::1", true, "IPv6 multicast"),
            // Non-multicast addresses
            ("192.168.1.1", false, "Private IPv4"),
            ("2001:db8::1", false, "IPv6 documentation"),
            ("223.255.255.255", false, "Just before multicast range"),
        ]
    )
    func testMulticast(input: String, expected: Bool, description: String) throws {
        let ip = try IPAddress(input)
        #expect(ip.isMulticast == expected, "\(description): \(input) should\(expected ? "" : " not") be multicast")
    }

    @Test(
        "Unspecified detection",
        arguments: [
            // Unspecified addresses
            ("0.0.0.0", true, "IPv4 unspecified"),
            ("::", true, "IPv6 unspecified"),
            // Specified addresses
            ("0.0.0.1", false, "Not unspecified IPv4"),
            ("192.168.1.1", false, "Private IPv4"),
            ("::1", false, "IPv6 loopback"),
            ("2001:db8::1", false, "IPv6 documentation"),
        ]
    )
    func testUnspecified(input: String, expected: Bool, description: String) throws {
        let ip = try IPAddress(input)
        #expect(ip.isUnspecified == expected, "\(description): \(input) should\(expected ? "" : " not") be unspecified")
    }

    @Test("Comparable - IPv4 ordering")
    func testIPv4Ordering() throws {
        let ip1 = try IPv4Address("192.168.1.1")
        let ip2 = try IPv4Address("192.168.1.2")
        let ip3 = try IPv4Address("192.168.2.1")

        #expect(ip1 < ip2)
        #expect(ip2 < ip3)
        #expect(ip1 < ip3)
        #expect(!(ip2 < ip1))
    }

    @Test("Comparable - IPv6 ordering")
    func testIPv6Ordering() throws {
        let ip1 = try IPv6Address("2001:db8::1")
        let ip2 = try IPv6Address("2001:db8::2")
        let ip3 = try IPv6Address("2001:db9::1")

        #expect(ip1 < ip2)
        #expect(ip2 < ip3)
        #expect(ip1 < ip3)
        #expect(!(ip2 < ip1))
    }

    @Test(
        "Equality",
        arguments: [
            ("192.168.1.1", "192.168.1.1", true, "Same IPv4"),
            ("192.168.1.1", "192.168.1.2", false, "Different IPv4"),
            ("2001:db8::1", "2001:0db8:0000:0000:0000:0000:0000:0001", true, "Same IPv6, different format"),
            ("2001:db8::1", "2001:db8::2", false, "Different IPv6"),
        ]
    )
    func testEquality(addr1: String, addr2: String, shouldBeEqual: Bool, description: String) throws {
        let ip1 = try IPAddress(addr1)
        let ip2 = try IPAddress(addr2)

        if shouldBeEqual {
            #expect(ip1 == ip2, "\(description): \(addr1) should equal \(addr2)")
        } else {
            #expect(ip1 != ip2, "\(description): \(addr1) should not equal \(addr2)")
        }
    }

    @Test("Hashable")
    func testHashable() throws {
        var dict: [IPAddress: String] = [:]

        let ip1 = try IPAddress("192.168.1.1")
        let ip2 = try IPAddress("2001:db8::1")

        dict[ip1] = "IPv4"
        dict[ip2] = "IPv6"

        #expect(dict[ip1] == "IPv4")
        #expect(dict[ip2] == "IPv6")
        #expect(dict.count == 2)
    }

    @Test(
        "Codable encodes to string representation",
        arguments: [
            "127.0.0.1",
            "192.168.1.1",
            "0.0.0.0",
            "255.255.255.255",
        ]
    )
    func testCodableEncodeIPv4(address: String) throws {
        let original = try IPAddress(address)
        let encoded = try JSONEncoder().encode(original)
        #expect(String(data: encoded, encoding: .utf8) == "\"\(address)\"")
    }

    @Test(
        "Codable decodes from string representation",
        arguments: [
            "127.0.0.1",
            "192.168.1.1",
            "0.0.0.0",
            "255.255.255.255",
        ]
    )
    func testCodableDecodeIPv4(address: String) throws {
        let json = Data("\"\(address)\"".utf8)
        let decoded = try JSONDecoder().decode(IPAddress.self, from: json)
        let expected = try IPAddress(address)
        #expect(decoded == expected)
    }

    @Test(
        "Codable encodes to string representation",
        arguments: [
            ("::1", "::1"),
            ("2001:db8::1", "2001:db8::1"),
            ("::", "::"),
            ("fe80::1", "fe80::1"),
        ]
    )
    func testCodableEncodeIPv6(input: String, expected: String) throws {
        let original = try IPAddress(input)
        let encoded = try JSONEncoder().encode(original)
        #expect(String(data: encoded, encoding: .utf8) == "\"\(expected)\"")
    }

    @Test(
        "Codable decodes from string representation",
        arguments: [
            "::1",
            "2001:db8::1",
            "::",
            "fe80::1",
        ]
    )
    func testCodableDecodeIPv6(address: String) throws {
        let json = Data("\"\(address)\"".utf8)
        let decoded = try JSONDecoder().decode(IPAddress.self, from: json)
        let expected = try IPAddress(address)
        #expect(decoded == expected)
    }
}
