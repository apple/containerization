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

@Suite("IPv6 Address Tests")
struct IPv6AddressTests {

    // MARK: - String Representation Tests (RFC 5952)

    @Test(
        "IPv6 address string representation - RFC 5952",
        arguments: [
            // Zero compression algorithm tests
            ("0:0:0:0:0:0:0:0", "::", "all zeros - unspecified address"),
            ("0:0:0:0:0:0:0:1", "::1", "leading zeros - loopback"),
            ("2001:0db8:0:0:0:0:0:0", "2001:db8::", "trailing zeros"),
            ("2001:0:0:0:0:0:0db8:1", "2001::db8:1", "middle zeros - longest run"),
            ("2001:0:0:0:0:0db8:0:1", "2001::db8:0:1", "multiple runs - prefer longest"),
            ("2001:0:0db8:0:1:0:0:2", "2001:0:db8:0:1::2", "tie-breaking - first occurrence wins"),
            ("2001:0:0db8:1:2:3:4:5", "2001:0:db8:1:2:3:4:5", "single zero - no compression (min 2 required)"),
            ("2001:0db8:0:0:1:2:3:4", "2001:db8::1:2:3:4", "exactly 2 zeros - minimum for compression"),
            ("0:0:0:0:1234:0:0:0", "::1234:0:0:0", "tie-breaking - first run wins (4 vs 3 zeros)"),

            // RFC 5952 formatting rules
            (
                "ABCD:EF01:2345:6789:9ABC:DEF0:1122:3344", "abcd:ef01:2345:6789:9abc:def0:1122:3344",
                "lowercase hex (Section 4.3)"
            ),
            ("0001:0002:0003:0004:0005:0006:0007:0008", "1:2:3:4:5:6:7:8", "no leading zeros (Section 4.1)"),

            // Edge cases
            ("2001:a:a:a:0:0db8:0:1", "2001:a:a:a:0:db8:0:1", "only single zeros scattered - no compression"),
        ]
    )
    func testIPv6StringRepresentation(input: String, expected: String, description: String) throws {
        let addr = try IPv6Address.parse(input)
        #expect(
            addr.description == expected,
            "Expected '\(expected)' but got '\(addr.description)' for input: '\(input)' (\(description))"
        )
    }

    // MARK: - isUnspecified Tests

    @Test(
        "isUnspecified - RFC 4291 Section 2.5.2",
        arguments: [
            ("::", true, "unspecified address (short form)"),
            ("0:0:0:0:0:0:0:0", true, "unspecified address (full form)"),
            (IPv6Address.unspecified.description, true, "unspecified"),
            ("::1", false, "loopback"),
            ("0:0:0:0:0:0:0:1", false, "loopback (full form)"),
            ("fe80::1", false, "link-local"),
            ("2001:db8::1", false, "global unicast"),
        ]
    )
    func testIsUnspecified(address: String, expected: Bool, description: String) throws {
        let addr = try IPv6Address.parse(address)
        #expect(
            addr.isUnspecified == expected,
            "Address \(address) (\(description)) should\(expected ? "" : " not") be unspecified"
        )
    }

    // MARK: - isLoopback Tests

    @Test(
        "isLoopback - RFC 4291 Section 2.5.3",
        arguments: [
            ("::1", true, "loopback (short form)"),
            ("0:0:0:0:0:0:0:1", true, "loopback (full form)"),
            (IPv6Address.loopback.description, true, "loopback var"),
            ("::", false, "unspecified"),
            ("::2", false, "not loopback"),
            ("0:0:0:0:0:0:0:2", false, "not loopback (full form)"),
            ("fe80::1", false, "link-local"),
            ("2001:db8::1", false, "global unicast"),
        ]
    )
    func testIsLoopback(addressString: String, expected: Bool, description: String) throws {
        let addr = try IPv6Address.parse(addressString)
        #expect(
            addr.isLoopback == expected,
            "Address \(addressString) (\(description)) should\(expected ? "" : " not") be loopback"
        )
    }

    // MARK: - isMulticast Tests

    @Test(
        "isMulticast - RFC 4291 Section 2.7",
        arguments: [
            // Positive cases - all multicast addresses start with ff
            ("ff00::1", true, "Reserved multicast"),
            ("ff01::1", true, "Interface-local multicast"),
            ("ff02::1", true, "Link-local multicast (all nodes)"),
            ("ff02::2", true, "Link-local multicast (all routers)"),
            ("ff05::1", true, "Site-local multicast"),
            ("ff0e::1", true, "Global multicast"),
            ("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true, "Max multicast"),
            // Negative cases
            ("::", false, "unspecified"),
            ("::1", false, "loopback"),
            ("fe80::1", false, "link-local unicast"),
            ("2001:db8::1", false, "global unicast"),
            ("fd00::1", false, "unique local"),
        ]
    )
    func testIsMulticast(addressString: String, expected: Bool, description: String) throws {
        let addr = try IPv6Address.parse(addressString)
        #expect(
            addr.isMulticast == expected,
            "Address \(addressString) (\(description)) should\(expected ? "" : " not") be multicast"
        )
    }

    // MARK: - isLinkLocal Tests

    @Test(
        "isLinkLocal - RFC 4291 Section 2.5.6",
        arguments: [
            // Positive cases - fe80::/10
            ("fe80::1", true, "basic link-local"),
            ("fe80::dead:beef", true, "link-local with hex"),
            ("fe80:0:0:0:0:0:0:1", true, "link-local (full form)"),
            ("fe80::1234:5678:90ab:cdef", true, "link-local with interface ID"),
            ("febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true, "Last address in fe80::/10"),
            // Negative cases
            ("::", false, "unspecified"),
            ("::1", false, "loopback"),
            ("fec0::1", false, "site-local (deprecated)"),
            ("ff02::1", false, "multicast"),
            ("2001:db8::1", false, "global unicast"),
            ("fd00::1", false, "unique local"),
        ]
    )
    func testIsLinkLocal(addressString: String, expected: Bool, description: String) throws {
        let addr = try IPv6Address.parse(addressString)
        #expect(
            addr.isLinkLocal == expected,
            "Address \(addressString) (\(description)) should\(expected ? "" : " not") be link-local"
        )
    }

    // MARK: - isUniqueLocal Tests

    @Test(
        "isUniqueLocal - RFC 4193",
        arguments: [
            // Positive cases - fc00::/7 (fc00::/8 and fd00::/8)
            ("fc00::1", true, "fc00 unique local"),
            ("fc00:dead:beef::1", true, "fc00 with hex"),
            ("fd00::1", true, "fd00 unique local"),
            ("fd12:3456:789a::1", true, "fd00 with prefix"),
            ("fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true, "max unique local"),
            // Negative cases
            ("::", false, "unspecified"),
            ("::1", false, "loopback"),
            ("fe80::1", false, "link-local"),
            ("ff02::1", false, "multicast"),
            ("2001:db8::1", false, "global unicast"),
        ]
    )
    func testIsUniqueLocal(addressString: String, expected: Bool, description: String) throws {
        let addr = try IPv6Address.parse(addressString)
        #expect(
            addr.isUniqueLocal == expected,
            "Address \(addressString) (\(description)) should\(expected ? "" : " not") be unique local"
        )
    }

    // MARK: - isGlobalUnicast Tests

    @Test(
        "isGlobalUnicast - RFC 4291 Section 2.5.4",
        arguments: [
            // Positive cases - routable on the global internet
            ("2001:db8::1", true, "Documentation (but still global unicast format)"),
            ("2001:4860:4860::8888", true, "Google DNS"),
            ("2606:4700:4700::1111", true, "Cloudflare DNS"),
            ("2001:500::1", true, "Root DNS server"),
            ("2a00:1450:4001::1", true, "Google"),
            // Negative cases - special addresses
            ("::", false, "unspecified"),
            ("::1", false, "loopback"),
            ("fe80::1", false, "link-local"),
            ("ff02::1", false, "multicast"),
            ("fc00::1", false, "unique local"),
            ("fd00::1", false, "unique local"),
        ]
    )
    func testIsGlobalUnicast(addressString: String, expected: Bool, description: String) throws {
        let addr = try IPv6Address.parse(addressString)
        #expect(
            addr.isGlobalUnicast == expected,
            "Address \(addressString) (\(description)) should\(expected ? "" : " not") be global unicast"
        )
    }

    // MARK: - isDocumentation Tests

    @Test(
        "isDocumentation - RFC 3849",
        arguments: [
            // Positive cases - 2001:db8::/32
            ("2001:db8::1", true, "basic documentation address"),
            ("2001:db8::", true, "documentation prefix"),
            ("2001:db8:0:0:0:0:0:1", true, "documentation (full form)"),
            ("2001:db8:1234:5678:90ab:cdef:1234:5678", true, "documentation with all fields"),
            ("2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", true, "max documentation address"),
            // Negative cases
            ("2001:db7::1", false, "Just before documentation range"),
            ("2001:db9::1", false, "Just after documentation range"),
            ("2001:4860:4860::8888", false, "Google DNS"),
            ("::", false, "unspecified"),
            ("::1", false, "loopback"),
        ]
    )
    func testIsDocumentation(addressString: String, expected: Bool, description: String) throws {
        let addr = try IPv6Address.parse(addressString)
        #expect(
            addr.isDocumentation == expected,
            "Address \(addressString) (\(description)) should\(expected ? "" : " not") be documentation"
        )
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
    func testCodableEncode(input: String, expected: String) throws {
        let original = try IPv6Address(input)
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
    func testCodableDecode(address: String) throws {
        let json = Data("\"\(address)\"".utf8)
        let decoded = try JSONDecoder().decode(IPv6Address.self, from: json)
        let expected = try IPv6Address(address)
        #expect(decoded == expected)
    }
}
