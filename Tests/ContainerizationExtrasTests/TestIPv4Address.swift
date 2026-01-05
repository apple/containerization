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

@Suite("IPv4Address Tests")
struct IPv4AddressTests {

    // MARK: - Initializer Tests

    @Suite("Initializers")
    struct InitializerTests {

        @Test(
            "UInt32 initializer",
            arguments: [
                (0x7F00_0001, "127.0.0.1"),  // localhost
                (0x0000_0000, "0.0.0.0"),  // zero address
                (0xFFFF_FFFF, "255.255.255.255"),  // max address
                (0xC0A8_0101, "192.168.1.1"),  // private network
                (0x0808_0808, "8.8.8.8"),  // Google DNS
            ]
        )
        func testUInt32Initializer(inputValue: UInt32, description: String) {
            let address = IPv4Address(inputValue)
            #expect(address.value == inputValue)
        }

        @Test(
            "String initializer - valid addresses",
            arguments: [
                ("127.0.0.1", 0x7F00_0001),  // localhost
                ("0.0.0.0", 0x0000_0000),  // zero address
                ("255.255.255.255", 0xFFFF_FFFF),  // broadcast
                ("10.0.0.1", 0x0A00_0001),  // private network 10.x
                ("192.168.1.1", 0xC0A8_0101),  // private network 192.168.x
                ("172.16.0.1", 0xAC10_0001),  // private network 172.16.x
                ("1.2.3.4", 0x0102_0304),  // single digits
                ("192.168.100.254", 0xC0A8_64FE),  // mixed digits
            ]
        )
        func testStringInitializerValid(addressString: String, expectedValue: UInt32) throws {
            let address = try IPv4Address(addressString)
            #expect(address.value == expectedValue)
        }

        @Test(
            "String initializer - invalid addresses",
            arguments: [
                "",  // empty string
                "1.2.3",  // too short
                "1.2.3.4.5",  // too many octets
                "192.168.1.256",  // octet out of range
                "192.168.001.1",  // leading zeros
                "01.2.3.4",  // leading zero first octet
                " 192.168.1.1",  // leading whitespace
                "192.168.1.1 ",  // trailing whitespace
                "192. 168.1.1",  // internal whitespace
                "192.168.1.a",  // invalid character
                "192.168.1.-1",  // negative number
                "192..1.1",  // missing octet
                ".168.1.1",  // missing first octet
                "192.168.1.",  // missing last octet
                "192.168.1.1.extra",  // too long
            ]
        )
        func testStringInitializerInvalid(invalidAddress: String) {
            #expect(throws: AddressError.self) {
                try IPv4Address(invalidAddress)
            }
        }
    }

    // MARK: - Property Tests

    @Suite("Properties")
    struct PropertyTests {

        @Test(
            "bytes property",
            arguments: [
                (UInt32(0x7F00_0001), [UInt8(127), UInt8(0), UInt8(0), UInt8(1)]),  // localhost
                (UInt32(0x0000_0000), [UInt8(0), UInt8(0), UInt8(0), UInt8(0)]),  // zero
                (UInt32(0xFFFF_FFFF), [UInt8(255), UInt8(255), UInt8(255), UInt8(255)]),  // broadcast
                (UInt32(0xC0A8_0101), [UInt8(192), UInt8(168), UInt8(1), UInt8(1)]),  // private network
                (UInt32(0x1234_5678), [UInt8(0x12), UInt8(0x34), UInt8(0x56), UInt8(0x78)]),  // byte order test
            ]
        )
        func testBytesProperty(inputValue: UInt32, expectedBytes: [UInt8]) {
            let address = IPv4Address(inputValue)
            #expect(address.bytes == expectedBytes)
        }

        @Test(
            "description property",
            arguments: [
                (0x7F00_0001, "127.0.0.1"),  // localhost
                (0x0000_0000, "0.0.0.0"),  // zero
                (0xFFFF_FFFF, "255.255.255.255"),  // broadcast
                (0xC0A8_0101, "192.168.1.1"),  // private network
                (0x0102_0304, "1.2.3.4"),  // single digits
            ]
        )
        func testDescriptionProperty(inputValue: UInt32, expectedDescription: String) {
            let address = IPv4Address(inputValue)
            #expect(address.description == expectedDescription)
        }

        @Test(
            "round-trip string conversion",
            arguments: [
                "0.0.0.0",
                "127.0.0.1",
                "192.168.1.1",
                "10.0.0.1",
                "172.16.0.1",
                "255.255.255.255",
                "1.2.3.4",
                "8.8.8.8",
                "1.1.1.1",
            ]
        )
        func testRoundTripStringConversion(addressString: String) throws {
            let address = try IPv4Address(addressString)
            #expect(address.description == addressString)
        }
    }

    // MARK: - Protocol Conformance Tests

    @Suite("Protocol Conformances")
    struct ProtocolConformanceTests {

        @Test("Equatable conformance")
        func testEquatableConformance() {
            let addr1 = IPv4Address(0x7F00_0001)
            let addr2 = IPv4Address(0x7F00_0001)
            let addr3 = IPv4Address(0xC0A8_0101)

            #expect(addr1 == addr2)
            #expect(addr1 != addr3)
            #expect(addr2 != addr3)
        }

        @Test("Hashable conformance")
        func testHashableConformance() {
            let addr1 = IPv4Address(0x7F00_0001)
            let addr2 = IPv4Address(0x7F00_0001)
            let addr3 = IPv4Address(0xC0A8_0101)

            // Equal objects should have equal hash values
            #expect(addr1.hashValue == addr2.hashValue)

            // Different objects should ideally have different hash values
            // (though this is not guaranteed, it's very likely for these values)
            #expect(addr1.hashValue != addr3.hashValue)

            // Test that addresses can be used in Sets and Dictionaries
            let addressSet: Set<IPv4Address> = [addr1, addr2, addr3]
            #expect(addressSet.count == 2)  // addr1 and addr2 are equal

            let addressDict = [addr1: "localhost", addr3: "private"]
            #expect(addressDict[addr2] == "localhost")  // addr2 equals addr1
        }

        @Test("CustomStringConvertible conformance")
        func testCustomStringConvertibleConformance() {
            let address = IPv4Address(0x7F00_0001)
            let stringRepresentation = String(describing: address)
            #expect(stringRepresentation == "127.0.0.1")
        }

        @Test("Sendable conformance")
        func testSendableConformance() {
            // This test verifies that IPv4Address can be safely passed across concurrency boundaries
            let address = IPv4Address(0x7F00_0001)

            Task {
                let taskAddress = address
                #expect(taskAddress.value == 0x7F00_0001)
            }
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
        func testCodableEncode(address: String) throws {
            let original = try IPv4Address(address)
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
        func testCodableDecode(address: String) throws {
            let json = Data("\"\(address)\"".utf8)
            let decoded = try JSONDecoder().decode(IPv4Address.self, from: json)
            let expected = try IPv4Address(address)
            #expect(decoded == expected)
        }
    }

    // MARK: - Edge Cases and Error Conditions

    @Suite("Edge Cases")
    struct EdgeCaseTests {

        @Test(
            "boundary values",
            arguments: [
                ("0.0.0.0", 0x0000_0000),  // minimum
                ("255.255.255.255", 0xFFFF_FFFF),  // maximum
                ("255.0.0.0", 0xFF00_0000),  // max first octet
                ("0.255.0.0", 0x00FF_0000),  // max second octet
                ("0.0.255.0", 0x0000_FF00),  // max third octet
                ("0.0.0.255", 0x0000_00FF),  // max fourth octet
            ]
        )
        func testBoundaryValues(addressString: String, expectedValue: UInt32) throws {
            let address = try IPv4Address(addressString)
            #expect(address.value == expectedValue)
        }

        @Test(
            "special addresses",
            arguments: [
                "127.0.0.1",  // loopback
                "255.255.255.255",  // broadcast
                "0.0.0.0",  // network address
                "8.8.8.8",  // Google DNS
                "1.1.1.1",  // Cloudflare DNS
            ]
        )
        func testSpecialAddresses(addressString: String) throws {
            let address = try IPv4Address(addressString)
            #expect(address.description == addressString)
        }

        @Test(
            "leading zero validation - invalid",
            arguments: [
                "01.0.0.0",
                "0.01.0.0",
                "0.0.01.0",
                "0.0.0.01",
                "192.168.001.1",
                "010.0.0.1",
                "00.0.0.1",
            ]
        )
        func testLeadingZeroValidationInvalid(invalidAddress: String) {
            #expect(throws: AddressError.self) {
                try IPv4Address(invalidAddress)
            }
        }

        @Test("leading zero validation - valid single zeros")
        func testLeadingZeroValidationValid() {
            // Single "0" should be valid
            #expect(throws: Never.self) {
                try IPv4Address("0.0.0.0")
            }
        }

        @Test(
            "string length validation - too short",
            arguments: [
                "", "1", "1.2", "1.2.3", "1.2.3.",
            ]
        )
        func testStringLengthValidationTooShort(shortString: String) {
            #expect(throws: AddressError.self) {
                try IPv4Address(shortString)
            }
        }

        @Test(
            "string length validation - too long",
            arguments: [
                "255.255.255.255.1",
                "1234.168.1.1",
                "192.1234.1.1",
                "192.168.1234.1",
                "192.168.1.1234",
            ]
        )
        func testStringLengthValidationTooLong(longString: String) {
            #expect(throws: AddressError.self) {
                try IPv4Address(longString)
            }
        }
    }

    // MARK: - Performance Tests

    @Suite("Performance")
    struct PerformanceTests {

        @Test("parsing performance")
        func testParsingPerformance() throws {
            let testAddresses = [
                "192.168.1.1",
                "10.0.0.1",
                "172.16.0.1",
                "127.0.0.1",
                "8.8.8.8",
                "1.1.1.1",
                "255.255.255.255",
                "0.0.0.0",
            ]

            // Warm up
            for _ in 0..<100 {
                for address in testAddresses {
                    _ = try IPv4Address(address)
                }
            }

            // Measure performance
            let iterations = 10000
            let startTime = Date()

            for _ in 0..<iterations {
                for address in testAddresses {
                    _ = try IPv4Address(address)
                }
            }

            let endTime = Date()
            let totalTime = endTime.timeIntervalSince(startTime)
            let averageTime = totalTime / Double(iterations * testAddresses.count)

            // Should be very fast - less than 1ms per parse on average
            #expect(averageTime < 0.001, "Parsing should be fast: \(averageTime)s per address")
        }

        @Test("bytes property performance")
        func testBytesPropertyPerformance() {
            let address = IPv4Address(0xC0A8_0101)

            let iterations = 100000
            let startTime = Date()

            for _ in 0..<iterations {
                _ = address.bytes
            }

            let endTime = Date()
            let totalTime = endTime.timeIntervalSince(startTime)
            let averageTime = totalTime / Double(iterations)

            // Should be very fast - less than 0.1ms per call on average
            #expect(averageTime < 0.0001, "Bytes property should be fast: \(averageTime)s per call")
        }

        @Test("description property performance")
        func testDescriptionPropertyPerformance() {
            let address = IPv4Address(0xC0A8_0101)

            let iterations = 10000
            let startTime = Date()

            for _ in 0..<iterations {
                _ = address.description
            }

            let endTime = Date()
            let totalTime = endTime.timeIntervalSince(startTime)
            let averageTime = totalTime / Double(iterations)

            // Should be reasonably fast - less than 1ms per call on average
            #expect(averageTime < 0.001, "Description property should be fast: \(averageTime)s per call")
        }
    }

    // MARK: - Integration Tests

    @Suite("Integration")
    struct IntegrationTests {

        @Test(
            "comprehensive round-trip test",
            arguments: [
                (0x0000_0000, "0.0.0.0"),
                (0x7F00_0001, "127.0.0.1"),
                (0xC0A8_0101, "192.168.1.1"),
                (0x0A00_0001, "10.0.0.1"),
                (0xAC10_0001, "172.16.0.1"),
                (0xFFFF_FFFF, "255.255.255.255"),
                (0x0808_0808, "8.8.8.8"),
                (0x0101_0101, "1.1.1.1"),
                (0x1234_5678, "18.52.86.120"),
                (0xDEAD_BEEF, "222.173.190.239"),
            ]
        )
        func testComprehensiveRoundTrip(expectedValue: UInt32, expectedString: String) throws {
            // Test UInt32 -> String
            let addressFromUInt32 = IPv4Address(expectedValue)
            #expect(addressFromUInt32.description == expectedString)

            // Test String -> UInt32
            let addressFromString = try IPv4Address(expectedString)
            #expect(addressFromString.value == expectedValue)

            // Test equality
            #expect(addressFromUInt32 == addressFromString)
        }

        @Test(
            "error message consistency",
            arguments: [
                "",
                "256.1.1.1",
                "1.2.3",
                "1.2.3.4.5",
                "192.168.001.1",
                " 192.168.1.1",
                "192.168.1.1 ",
                "192.168.1.a",
            ]
        )
        func testErrorMessageConsistency(invalidInput: String) {
            do {
                _ = try IPv4Address(invalidInput)
                #expect(Bool(false), "Should have thrown for input: \(invalidInput)")
            } catch let error as AddressError {
                #expect(error == AddressError.unableToParse)
            } catch {
                #expect(Bool(false), "Should have thrown AddressError, got: \(error)")
            }
        }
    }
}
