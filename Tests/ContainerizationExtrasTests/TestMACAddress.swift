//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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

@Suite("MACAddress Tests")
struct MACAddressTests {

    // MARK: - Initializer Tests

    @Suite("Initializers")
    struct InitializerTests {

        @Test(
            "UInt64 initializer - valid addresses",
            arguments: [
                //(0x0123_4567_89ab, "01:23:45:67:89:ab"),  // a valid address
                //(0x0000_0000_0000, "00:00:00:00:00:00"),  // zero address
                //(0xFFFF_FFFF_FFFF, "ff:ff:ff:ff:ff:ff"),  // max address
                (0xffff_0123_4567_89ab, "01:23:45:67:89:ab")  // drops the most significant 16 bits
            ]
        )
        func testUInt64InitializerValid(inputValue: UInt64, description: String) {
            let address = MACAddress(inputValue)
            #expect(address.value == inputValue & 0x0000_ffff_ffff_ffff)
        }

        @Test(
            "String initializer - valid addresses",
            arguments: [
                ("01:23:45:67:89:ab", 0x0123_4567_89ab),  // colon separators
                ("01-23-45-67-89-ab", 0x0123_4567_89ab),  // dash separators
                ("ab:cd:ef:AB:CD:EF", 0xabcd_efab_cdef),  // mixed case
                ("00:00:00:00:00:00", 0x0000_0000_0000),  // zero address
                ("ff:ff:ff:ff:ff:ff", 0xffff_ffff_ffff),  // max address
            ]
        )
        func testStringInitializerValid(addressString: String, expectedValue: UInt64) throws {
            let address = try MACAddress(addressString)
            #expect(address.value == expectedValue)
        }

        @Test(
            "String initializer - invalid addresses",
            arguments: [
                "",  // empty string
                "01:23:45:67:89",  // too few octets
                "01:23:45:67:89:ab:cd",  // too many octets
                "01:23:45:67:89:",  // empty octet
                ":23:45:67:89:ab",  // empty octet
                "01::45:67:89:ab",  // empty octet
                "01:23:45:67:89:a",  // short octet
                "1:23:45:67:89:ab",  // short octet
                "01:2:45:67:89:ab",  // short octet
                "01:23:45:67:89:abc",  // long octet
                "012:23:45:67:89:ab",  // long octet
                "01:234:45:67:89:ab",  // long octet
                "01:23:45:67:89:@G",  // invalid content 0x40, 0x47
                "`g:23:45:67:89:ab",  // invalid content 0x60, 0x67
                "01:hi:45:67:89:ab",  // invalid content
                " 01:23:45:67:89:ab",  // leading whitespace
                "01:23:45:67:89:ab ",  // trailing whitespace
                "01: 23:45:67:89:ab",  // internal whitespace
            ]
        )
        func testStringInitializerInvalid(invalidAddress: String) {
            #expect(throws: AddressError.self) {
                try MACAddress(invalidAddress)
            }
        }
    }

    // MARK: - Property Tests

    @Suite("Properties")
    struct PropertyTests {

        @Test(
            "bytes property",
            arguments: [
                (
                    UInt64(0x0123_4567_89ab),
                    [UInt8(0x01), UInt8(0x23), UInt8(0x45), UInt8(0x67), UInt8(0x89), UInt8(0xab)]
                ),
                (
                    UInt64(0x0000_0000_0000),
                    [UInt8(0x00), UInt8(0x00), UInt8(0x00), UInt8(0x00), UInt8(0x00), UInt8(0x00)]
                ),
                (
                    UInt64(0xffff_ffff_ffff),
                    [UInt8(0xff), UInt8(0xff), UInt8(0xff), UInt8(0xff), UInt8(0xff), UInt8(0xff)]
                ),
                (
                    UInt64(0xffff_0123_4567_89ab),
                    [UInt8(0x01), UInt8(0x23), UInt8(0x45), UInt8(0x67), UInt8(0x89), UInt8(0xab)]
                ),
            ]
        )
        func testBytesProperty(inputValue: UInt64, expectedBytes: [UInt8]) {
            let address = MACAddress(inputValue)
            #expect(address.bytes == expectedBytes)
        }

        @Test(
            "description property",
            arguments: [
                (0x0123_4567_89ab, "01:23:45:67:89:ab"),
                (0x0000_0000_0000, "00:00:00:00:00:00"),
                (0xffff_ffff_ffff, "ff:ff:ff:ff:ff:ff"),
                (0xffff_0123_4567_89ab, "01:23:45:67:89:ab"),
            ]
        )
        func testDescriptionProperty(inputValue: UInt64, expectedDescription: String) {
            let address = MACAddress(inputValue)
            #expect(address.description == expectedDescription)
        }

        @Test(
            "isLocallyAdministered property",
            arguments: [
                (0x0000_1234_5678, false),
                (0x0200_1234_5678, true),
            ]
        )
        func testIsLocallyAdministeredProperty(inputValue: UInt64, expectedValue: Bool) {
            let address = MACAddress(inputValue)
            #expect(address.isLocallyAdministered == expectedValue)
        }

        @Test(
            "isMulticast property",
            arguments: [
                (0x0000_1234_5678, false),
                (0x0100_1234_5678, true),
            ]
        )
        func testIsMulticastProperty(inputValue: UInt64, expectedValue: Bool) {
            let address = MACAddress(inputValue)
            #expect(address.isMulticast == expectedValue)
        }

        @Test(
            "round-trip string conversion",
            arguments: [
                "01:23:45:67:89:ab",
                "00:00:00:00:00:00",
                "ff:ff:ff:ff:ff:ff",
                "01-23-45-67-89-AB",
            ]
        )
        func testRoundTripStringConversion(addressString: String) throws {
            let address = try MACAddress(addressString)
            #expect(address.description == addressString.lowercased().replacingOccurrences(of: "-", with: ":"))
        }
    }

    // MARK: - Link Local Address Tests

    @Suite("Link Local Addresses")
    struct LinkLocalAddressTests {

        @Test(
            "Link local address",
            arguments: [
                (0x39a7_9407_cbd0, 0xfd97_7b15_d62e_75ac_3ba7_94ff_fe07_cbd0),
                (0x5e3b_68d7_e510, 0xfd97_7b15_d62e_75ac_5c3b_68ff_fed7_e510),
            ]
        )
        func testLinkLocalAddress(mac: UInt64, ipv6: UInt128) {
            let mac = MACAddress(mac)
            let ipv6Prefix = IPv6Address(ipv6 & 0xffff_ffff_ffff_ffff_0000_0000_0000_0000)
            #expect(mac.ipv6Address(network: ipv6Prefix) == IPv6Address(ipv6))
        }
    }

    // MARK: - Protocol Conformance Tests

    @Suite("Protocol Conformances")
    struct ProtocolConformanceTests {

        @Test("Equatable conformance")
        func testEquatableConformance() {
            let addr1 = MACAddress(0x0123_4567_89ab)
            let addr2 = MACAddress(0x0123_4567_89ab)
            let addr3 = MACAddress(0x0123_4567_89ac)

            #expect(addr1 == addr2)
            #expect(addr1 != addr3)
            #expect(addr2 != addr3)
        }

        @Test("Hashable conformance")
        func testHashableConformance() {
            let addr1 = MACAddress(0x0123_4567_89ab)
            let addr2 = MACAddress(0x0123_4567_89ab)
            let addr3 = MACAddress(0x0123_4567_89ac)

            // Equal objects should have equal hash values
            #expect(addr1.hashValue == addr2.hashValue)

            // Different objects should ideally have different hash values
            // (though this is not guaranteed, it's very likely for these values)
            #expect(addr1.hashValue != addr3.hashValue)

            // Test that addresses can be used in Sets and Dictionaries
            let addressSet: Set<MACAddress> = [addr1, addr2, addr3]
            #expect(addressSet.count == 2)  // addr1 and addr2 are equal

            let addressDict = [addr1: "localhost", addr3: "private"]
            #expect(addressDict[addr2] == "localhost")  // addr2 equals addr1
        }

        @Test("CustomStringConvertible conformance")
        func testCustomStringConvertibleConformance() {
            let address = MACAddress(0x0123_4567_89ab)
            let stringRepresentation = String(describing: address)
            #expect(stringRepresentation == "01:23:45:67:89:ab")
        }

        @Test("Sendable conformance")
        func testSendableConformance() {
            // This test verifies that MACAddress can be safely passed across concurrency boundaries
            let address = MACAddress(0x0123_4567_89ab)

            Task {
                let taskAddress = address
                #expect(taskAddress.value == 0x0123_4567_89ab)
            }
        }
    }

    // MARK: - Performance Tests

    @Suite("Performance")
    struct PerformanceTests {

        @Test("parsing performance")
        func testParsingPerformance() throws {
            let testAddresses = [
                "01:23:45:67:89:ab",
                "01-23-45-67-89-ab",
                "01-23-45-67-89-a",
                "01-23-45-67-89-abc",
            ]

            // Warm up
            for _ in 0..<100 {
                for address in testAddresses {
                    _ = try? MACAddress(address)
                }
            }

            // Measure performance
            let iterations = 10000
            let startTime = Date()

            for _ in 0..<iterations {
                for address in testAddresses {
                    _ = try? MACAddress(address)
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
            let address = MACAddress(0x0123_4567_89ab)

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
            let address = MACAddress(0x0123_4567_89ab)

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
                (0x0123_4567_89ab, "01:23:45:67:89:ab"),
                (0x0000_0000_0000, "00:00:00:00:00:00"),
                (0xffff_ffff_ffff, "ff:ff:ff:ff:ff:ff"),
            ]
        )
        func testComprehensiveRoundTrip(expectedValue: UInt64, expectedString: String) throws {
            // Test UInt32 -> String
            let addressFromUInt32 = MACAddress(expectedValue)
            #expect(addressFromUInt32.description == expectedString)

            // Test String -> UInt32
            let addressFromString = try MACAddress(expectedString)
            #expect(addressFromString.value == expectedValue)

            // Test equality
            #expect(addressFromUInt32 == addressFromString)
        }

        @Test(
            "error message consistency",
            arguments: [
                "",
                "hi:00:00:00:00:00",
                "01:23:45:67:89",
                "01:23:45:67:89:ab:cd",
                "001:23:45:67:89:ab:cd",
                " 01:23:45:67:89:ab:cd",
                "01:23:45:67:89:ab:cd ",
            ]
        )
        func testErrorMessageConsistency(invalidInput: String) {
            do {
                _ = try MACAddress(invalidInput)
                #expect(Bool(false), "Should have thrown for input: \(invalidInput)")
            } catch let error as AddressError {
                #expect(error == AddressError.unableToParse)
            } catch {
                #expect(Bool(false), "Should have thrown AddressError, got: \(error)")
            }
        }

        @Test(
            "Codable encodes to string representation",
            arguments: [
                "01:23:45:67:89:ab",
                "00:00:00:00:00:00",
                "ff:ff:ff:ff:ff:ff",
            ]
        )
        func testCodableEncode(address: String) throws {
            let original = try MACAddress(address)
            let encoded = try JSONEncoder().encode(original)
            #expect(String(data: encoded, encoding: .utf8) == "\"\(address)\"")
        }

        @Test(
            "Codable decodes from string representation",
            arguments: [
                "01:23:45:67:89:ab",
                "00:00:00:00:00:00",
                "ff:ff:ff:ff:ff:ff",
            ]
        )
        func testCodableDecode(address: String) throws {
            let json = Data("\"\(address)\"".utf8)
            let decoded = try JSONDecoder().decode(MACAddress.self, from: json)
            let expected = try MACAddress(address)
            #expect(decoded == expected)
        }
    }
}
