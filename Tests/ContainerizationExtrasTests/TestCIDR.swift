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

struct TestCIDR {

    // MARK: - Normalization Tests

    struct Normalization {
        let input: String
        let expectedNetwork: String
        let expectedLength: UInt8
    }

    @Test(arguments: [
        Normalization(
            input: "192.168.1.100/24",
            expectedNetwork: "192.168.1.0",
            expectedLength: 24
        ),
        Normalization(
            input: "10.1.2.3/16",
            expectedNetwork: "10.1.0.0",
            expectedLength: 16
        ),
        Normalization(
            input: "2001:db8::1234/64",
            expectedNetwork: "2001:db8::",
            expectedLength: 64
        ),
        Normalization(
            input: "172.16.0.1/12",
            expectedNetwork: "172.16.0.0",
            expectedLength: 12
        ),
    ])
    func testNormalization(testCase: Normalization) throws {
        let cidr = try CIDR(testCase.input)
        #expect(cidr.lower.description == testCase.expectedNetwork)
        #expect(cidr.prefix.length == testCase.expectedLength)
    }

    struct ParsePreservation {
        let input: String
        let expectedIP: String
        let expectedLength: UInt8
    }

    // MARK: - Bounds Tests

    struct Bounds {
        let cidr: String
        let lower: String
        let upper: String
    }

    @Test(arguments: [
        Bounds(
            cidr: "192.168.1.0/24",
            lower: "192.168.1.0",
            upper: "192.168.1.255"
        ),
        Bounds(
            cidr: "10.0.0.0/8",
            lower: "10.0.0.0",
            upper: "10.255.255.255"
        ),
        Bounds(
            cidr: "2001:db8::/64",
            lower: "2001:db8::",
            upper: "2001:db8::ffff:ffff:ffff:ffff"
        ),
        Bounds(
            cidr: "192.168.1.0/32",
            lower: "192.168.1.0",
            upper: "192.168.1.0"
        ),
    ])
    func testBounds(testCase: Bounds) throws {
        let block = try CIDR(testCase.cidr)
        #expect(block.lower.description == testCase.lower)
        #expect(block.upper.description == testCase.upper)
    }

    // MARK: - Containment Tests

    struct IPContainment {
        let cidr: String
        let ip: String
        let shouldContain: Bool
    }

    @Test(arguments: [
        IPContainment(
            cidr: "192.168.1.0/24",
            ip: "192.168.1.100",
            shouldContain: true
        ),
        IPContainment(
            cidr: "192.168.1.0/24",
            ip: "192.168.2.1",
            shouldContain: false
        ),
        IPContainment(
            cidr: "10.0.0.0/8",
            ip: "10.255.255.255",
            shouldContain: true
        ),
        IPContainment(
            cidr: "10.0.0.0/8",
            ip: "11.0.0.1",
            shouldContain: false
        ),
        IPContainment(
            cidr: "2001:db8::/32",
            ip: "2001:db8::1",
            shouldContain: true
        ),
    ])
    func testContainsIP(testCase: IPContainment) throws {
        let block = try CIDR(testCase.cidr)
        let address = try IPAddress(testCase.ip)
        #expect(block.contains(address) == testCase.shouldContain)
    }

    @Test func testDoesNotContainDifferentIPv6Zone() throws {
        let cidr = try CIDR("fe80::1/64")
        let ip = try IPv6Address("fe80::2%eth1")
        #expect(!cidr.contains(.v6(ip)))
    }

    // MARK: - Range Constructor

    @Test func testRangeConstructorFindsSmallestBlock() throws {
        let lower = try IPAddress("192.168.1.0")
        let upper = try IPAddress("192.168.1.255")
        let cidr = try CIDR(lower: lower, upper: upper)
        #expect(cidr.prefix.length == 24)
        #expect(cidr.address.description == "192.168.1.0")
    }

    @Test func testRangeConstructorSingleIPv4() throws {
        let ip = try IPAddress("192.168.1.100")
        let cidr = try CIDR(lower: ip, upper: ip)
        #expect(cidr.prefix.length == 32)
        #expect(cidr.address.description == "192.168.1.100")
    }

    @Test func testRangeConstructorIPv6() throws {
        let lower = try IPAddress("2001:db8::")
        let upper = try IPAddress("2001:db8::ffff:ffff:ffff:ffff")
        let cidr = try CIDR(lower: lower, upper: upper)
        #expect(cidr.prefix.length == 64)
        #expect(cidr.address.description == "2001:db8::")
    }

    @Test func testRangeConstructorSingleIPv6() throws {
        let ip = try IPAddress("2001:db8::1")
        let cidr = try CIDR(lower: ip, upper: ip)
        #expect(cidr.prefix.length == 128)
        #expect(cidr.address.description == "2001:db8::1")
    }

    @Test func testRangeConstructorRejectsMixedVersions() throws {
        #expect(throws: CIDR.Error.self) {
            let v4 = try IPAddress("192.168.1.0")
            let v6 = try IPAddress("2001:db8::1")
            _ = try CIDR(lower: v4, upper: v6)
        }
    }

    @Test func testRangeConstructorRejectsDifferentZones() throws {
        #expect(throws: CIDR.Error.self) {
            let lower = IPAddress.v6(try IPv6Address("fe80::1%eth0"))
            let upper = IPAddress.v6(try IPv6Address("fe80::2%eth1"))
            _ = try CIDR(lower: lower, upper: upper)
        }
    }

    // MARK: - Validation Tests

    struct InvalidInput {
        let input: String
    }

    @Test(arguments: [
        InvalidInput(input: "192.168.1.0/33"),  // IPv4 prefix too large
        InvalidInput(input: "2001:db8::/129"),  // IPv6 prefix too large
        InvalidInput(input: "192.168.1.0"),  // Missing prefix
        InvalidInput(input: "192.168.1.0/"),  // Empty prefix
        InvalidInput(input: "192.168.1.0/abc"),  // Invalid prefix
    ])
    func testRejectsInvalidInput(testCase: InvalidInput) throws {
        #expect(throws: CIDR.Error.self) {
            try CIDR(testCase.input)
        }
    }

    @Test func testRejectsInvalidRangeOrder() throws {
        #expect(throws: CIDR.Error.self) {
            let lower = try IPAddress("192.168.1.255")
            let upper = try IPAddress("192.168.1.0")
            _ = try CIDR(lower: lower, upper: upper)
        }
    }

    // MARK: - Range Constructor Validation Tests

    @Test func testRangeConstructorValidatesContainment() throws {
        // This should work: 192.168.1.64 to 192.168.1.127 -> /26
        let lower1 = try IPAddress("192.168.1.64")
        let upper1 = try IPAddress("192.168.1.127")
        let cidr1 = try CIDR(lower: lower1, upper: upper1)
        #expect(cidr1.prefix.length == 26)
        #expect(cidr1.contains(lower1))
        #expect(cidr1.contains(upper1))
    }

    @Test func testRangeConstructorValidatesIPv6Containment() throws {
        // Test IPv6 range containment validation
        let lower = try IPAddress("2001:db8::1000")
        let upper = try IPAddress("2001:db8::1fff")
        let cidr = try CIDR(lower: lower, upper: upper)
        #expect(cidr.contains(lower))
        #expect(cidr.contains(upper))
    }

    // MARK: - Version-Specific Range Constructors

    @Test func testV4RangeConstructor() throws {
        let lower = try IPAddress("192.168.1.0")
        let upper = try IPAddress("192.168.1.255")
        let cidr = try CIDR(lower: lower, upper: upper)
        #expect(cidr.prefix.length == 24)
        #expect(cidr.address.description == "192.168.1.0")
    }

    @Test func testV4RangeSingleAddress() throws {
        let addr = try IPAddress("192.168.1.100")
        let cidr = try CIDR(lower: addr, upper: addr)
        #expect(cidr.prefix.length == 32)
        #expect(cidr.address.description == "192.168.1.100")
    }

    @Test func testV6RangeConstructor() throws {
        let lower = try IPAddress("2001:db8::")
        let upper = try IPAddress("2001:db8::ffff:ffff:ffff:ffff")
        let cidr = try CIDR(lower: lower, upper: upper)
        #expect(cidr.prefix.length == 64)
        #expect(cidr.address.description == "2001:db8::")
    }

    @Test func testV6RangeSingleAddress() throws {
        let addr = try IPAddress("2001:db8::1")
        let cidr = try CIDR(lower: addr, upper: addr)
        #expect(cidr.prefix.length == 128)
        #expect(cidr.address.description == "2001:db8::1")
    }

    @Test func testV4RangeRejectsInvalidOrder() throws {
        let lower = try IPAddress("192.168.1.255")
        let upper = try IPAddress("192.168.1.0")
        #expect(throws: CIDR.Error.self) {
            _ = try CIDR(lower: lower, upper: upper)
        }
    }

    @Test func testV6RangeRejectsInvalidOrder() throws {
        let lower = try IPAddress("2001:db8::ffff")
        let upper = try IPAddress("2001:db8::1")
        #expect(throws: CIDR.Error.self) {
            _ = try CIDR(lower: lower, upper: upper)
        }
    }

    @Test func testV6RangeRejectsDifferentZones() throws {
        let lower = try IPAddress("fe80::1%eth0")
        let upper = try IPAddress("fe80::2%eth1")
        #expect(throws: CIDR.Error.self) {
            _ = try CIDR(lower: lower, upper: upper)
        }
    }

    // MARK: - Description Tests

    @Test func testDescriptionFormat() throws {
        let cidr = try CIDR("10.0.0.0/8")
        #expect(cidr.description == "10.0.0.0/8")
    }

    @Test func testPreservesAddress() throws {
        let cidr = try CIDR("192.168.1.100/24")
        #expect(cidr.description == "192.168.1.100/24")
    }

    @Test(
        "CIDRv4 Codable encodes to string representation",
        arguments: [
            "192.168.1.0/24",
            "10.0.0.0/8",
            "172.16.0.0/12",
        ]
    )
    func testCIDRv4CodableEncode(cidr: String) throws {
        let original = try CIDRv4(cidr)
        let encoded = try JSONEncoder().encode(original)
        let jsonString = String(data: encoded, encoding: .utf8)!
        #expect(jsonString.contains(original.address.description))
        #expect(jsonString.contains("\(original.prefix.length)"))
    }

    @Test(
        "CIDRv4 Codable decodes from string representation",
        arguments: [
            "192.168.1.0/24",
            "10.0.0.0/8",
            "172.16.0.0/12",
        ]
    )
    func testCIDRv4CodableDecode(cidr: String) throws {
        let json = Data("\"\(cidr)\"".utf8)
        let decoded = try JSONDecoder().decode(CIDRv4.self, from: json)
        let expected = try CIDRv4(cidr)
        #expect(decoded == expected)
    }

    @Test(
        "CIDRv6 Codable encodes to string representation",
        arguments: [
            ("2001:db8::/32", "2001:db8::", 32),
            ("fe80::/10", "fe80::", 10),
            ("::1/128", "::1", 128),
        ]
    )
    func testCIDRv6CodableEncode(cidr: String, expectedAddr: String, expectedPrefix: UInt8) throws {
        let original = try CIDRv6(cidr)
        let encoded = try JSONEncoder().encode(original)
        let jsonString = String(data: encoded, encoding: .utf8)!
        #expect(jsonString.contains(expectedAddr))
        #expect(jsonString.contains("\(expectedPrefix)"))
    }

    @Test(
        "CIDRv6 Codable decodes from string representation",
        arguments: [
            "2001:db8::/32",
            "fe80::/10",
            "::1/128",
        ]
    )
    func testCIDRv6CodableDecode(cidr: String) throws {
        let json = Data("\"\(cidr)\"".utf8)
        let decoded = try JSONDecoder().decode(CIDRv6.self, from: json)
        let expected = try CIDRv6(cidr)
        #expect(decoded == expected)
    }
}
