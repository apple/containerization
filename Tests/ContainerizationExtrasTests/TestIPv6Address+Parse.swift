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

@Suite("IPv6Address Parsing Tests")
struct IPv6AddressParseTests {

    // MARK: - Valid Hexadecimal Group Tests

    @Test(
        "Parsing valid hexadecimal groups",
        arguments: [
            ("0", 0x0),
            ("1", 0x1),
            ("F", 0xF),
            ("FF", 0xFF),
            ("FFF", 0xFFF),
            ("FFFF", 0xFFFF),
            ("1234", 0x1234),
            ("abcd", 0xABCD),
            ("ABCD", 0xABCD),
            ("0000", 0x0000),
        ]
    )
    func testParseValidHexadecimalGroups(input: String, expectedValue: UInt16) throws {
        let utf8 = input.utf8
        let (parsedValue, nextIndex) = try IPv6Address.parseHexadecimal(
            from: utf8,
            startingAt: utf8.startIndex
        )

        #expect(
            parsedValue == expectedValue,
            "For input '\(input)': expected \(expectedValue) but got \(parsedValue)"
        )
        #expect(nextIndex == input.endIndex, "Parser should consume entire input")
    }

    @Test(
        "Parsing hexadecimal groups with trailing characters",
        arguments: [
            ("FF:1234", 0xFF, ":1234"),
            ("1234G", 0x1234, "G"),
            ("AB::CD", 0xAB, "::CD"),
            ("0Z", 0x0, "Z"),
        ]
    )
    func testParseHexadecimalGroupWithTrailingCharacters(
        input: String,
        expectedValue: UInt16,
        expectedRemainder: String
    ) throws {
        let utf8 = input.utf8
        let (parsedValue, nextIndex) = try IPv6Address.parseHexadecimal(
            from: utf8,
            startingAt: utf8.startIndex
        )

        let remainder = String(input[String.Index(nextIndex, within: input)!...])

        #expect(
            parsedValue == expectedValue,
            "For input '\(input)': expected \(expectedValue) but got \(parsedValue)"
        )
        #expect(
            remainder == expectedRemainder,
            "For input '\(input)': expected remainder '\(expectedRemainder)' but got '\(remainder)'"
        )
    }

    // MARK: - Error Handling Tests

    @Test(
        "Parsing invalid hexadecimal groups should throw",
        arguments: [
            "",  // Empty string - no hex digits found
            "G",  // Invalid hex character - no hex digits found
            "GGGG",  // All invalid hex characters - no hex digits found
        ]
    )
    func testParseInvalidHexadecimalGroup(invalidInput: String) {
        #expect(throws: AddressError.self) {
            let utf8 = invalidInput.utf8
            _ = try IPv6Address.parseHexadecimal(
                from: utf8,
                startingAt: utf8.startIndex
            )
        }
    }

    @Test(
        "Parsing hexadecimal groups with overflow behavior",
        arguments: [
            ("12345", 0x1234, "5"),  // 5 digits -> takes first 4
            ("10000", 0x1000, "0"),  // 5 digits -> takes first 4
            ("FFFFF", 0xFFFF, "F"),  // 5 digits -> takes first 4
            ("123456789", 0x1234, "56789"),  // Many digits -> takes first 4
        ]
    )
    func testParseHexadecimalGroupOverflow(
        input: String,
        expectedValue: UInt16,
        expectedRemainder: String
    ) throws {
        let utf8 = input.utf8
        let (parsedValue, nextIndex) = try IPv6Address.parseHexadecimal(
            from: utf8,
            startingAt: utf8.startIndex
        )

        let remainder = String(input[String.Index(nextIndex, within: input)!...])

        #expect(
            parsedValue == expectedValue,
            "For input '\(input)': expected \(expectedValue) but got \(parsedValue)"
        )
        #expect(
            remainder == expectedRemainder,
            "For input '\(input)': expected remainder '\(expectedRemainder)' but got '\(remainder)'"
        )
    }

    @Test("Parsing from middle of string")
    func testParseHexadecimalGroupFromMiddle() throws {
        let input = "prefix1234suffix"
        let utf8 = input.utf8
        let startIndex = utf8.index(utf8.startIndex, offsetBy: 6)  // Start at "1234"

        let (parsedValue, nextIndex) = try IPv6Address.parseHexadecimal(
            from: utf8,
            startingAt: startIndex
        )

        #expect(parsedValue == 0x1234)

        let remainder = String(input[String.Index(nextIndex, within: input)!...])
        #expect(remainder == "suffix")
    }

    // MARK: - Performance Tests

    @Test("Performance with maximum length hex groups")
    func testParsePerformance() throws {
        let testInput = "FFFF"

        // Measure performance of parsing operation
        let startTime = CFAbsoluteTimeGetCurrent()
        let count = 10000
        for _ in 0..<count {
            let utf8 = testInput.utf8
            _ = try IPv6Address.parseHexadecimal(
                from: utf8,
                startingAt: utf8.startIndex
            )
        }

        let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime

        // Expect parsing to be reasonably fast (less than 1ms per operation on average)
        print("Parsed \(count) IPv6 addresses in \(timeElapsed)s")
        #expect(timeElapsed < 0.1, "Parsing should be performant: \(timeElapsed)s for 10000 operations")
    }

    // MARK: - RFC 4291 Section 2.3 Text Representation of Address Prefixes Tests

    @Test("RFC 4291 Section 2.3 - Valid address prefix representations")
    func testRFC4291Section23ValidPrefixRepresentations() throws {
        // Examples of valid 60-bit prefix 20010DB80000CD3 (hexadecimal)
        let validPrefixCases = [
            "2001:0DB8:0000:CD30:0000:0000:0000:0000/60",
            "2001:0DB8::CD30:0:0:0:0/60",
            "2001:0DB8:0:CD30::/60",
        ]

        let parsed = try validPrefixCases.map { testCase in
            let addressPart = String(testCase.prefix(while: { $0 != "/" }))
            return try IPv6Address.parse(addressPart).bytes
        }

        #expect(
            parsed.allSatisfy { $0 == parsed.first },
            "All valid prefix representations should parse to identical byte arrays"
        )
    }

    @Test("RFC 4291 Section 2.3 - Invalid address prefix representations")
    func testRFC4291Section23InvalidPrefixRepresentations() throws {
        // RFC 4291 Section 2.3 examples of invalid representations
        let invalidPrefixCases = [
            "2001:0DB8:0:CD3/60",  // ex 1: may drop leading zeros, but not trailing zeros"
            "2001:0DB8::CD30/60",  // ex 2: expands to wrong address
            "2001:0DB8::CD3/60",  // ex 3: expands to wrong address
        ]

        let validAddress = "2001:0DB8:0000:CD30:0000:0000:0000:0000"
        let parsedValidAddress: [UInt8] = [32, 1, 13, 184, 0, 0, 205, 48, 0, 0, 0, 0, 0, 0, 0, 0]
        let parsedLibValidAddress = try IPv6Address.parse(validAddress).bytes
        #expect(parsedLibValidAddress == parsedValidAddress)

        for testCase in invalidPrefixCases {
            let addressPart = String(testCase.prefix(while: { $0 != "/" }))

            do {
                let actualBytes = try IPv6Address.parse(addressPart).bytes
                #expect(actualBytes != parsedValidAddress, "\(testCase) should not match valid prefix")
            } catch {
                // If parsing fails, that's also acceptable for invalid representations
                #expect(error is AddressError, "\(testCase) should throw IPAddressError if it fails to parse")
            }
        }
    }

    @Test(
        "RFC 4291 Section 2.3 - Leading zero rules in prefixes",
        arguments: [
            ("2001:DB8:0:0CD3::", "2001:DB8:0:CD3::", "Can drop leading zeros 0CD3 -> CD3"),
            ("2001:0DB8::", "2001:DB8::", "Can drop leading zeros 0DB8 -> DB8"),
            ("0001:0002:0003::", "1:2:3::", "Can drop leading zeros in multiple groups"),
        ]
    )
    func testRFC4291Section23LeadingZeroRules(form1: String, form2: String, description: String) throws {
        let bytes1 = try IPv6Address.parse(form1).bytes
        let bytes2 = try IPv6Address.parse(form2).bytes
        #expect(bytes1 == bytes2, "\(description)")
    }

    @Test(
        "RFC 4291 Section 2.3 - cannot drop trailing zeros",
        arguments: [
            ("2001:DB8:0:CD30::", "2001:DB8:0:CD3::", "Cannot drop trailing zeros in CD30 -> CD3"),
            ("2001:DB80::", "2001:DB8::", "Cannot drop trailing zero DB80 -> DB8"),
            ("ABCD:EF00::", "ABCD:EF::", "Cannot drop trailing zeros EF00 -> EF"),
        ]
    )
    func testRFC4291Section23CannotDropTrailingZeros(full: String, truncated: String, description: String) throws {
        let fullBytes = try IPv6Address.parse(full).bytes
        let truncatedBytes = try IPv6Address.parse(truncated).bytes
        #expect(fullBytes != truncatedBytes, "\(description)")
    }

    @Test("RFC 4291 Section 2.3 - Node address and subnet prefix combination")
    func testRFC4291Section23NodeAddressSubnetCombination() throws {
        // RFC example: node address 2001:0DB8:0:CD30:123:4567:89AB:CDEF
        // and its subnet number 2001:0DB8:0:CD30::/60
        // can be abbreviated as 2001:0DB8:0:CD30:123:4567:89AB:CDEF/60

        let nodeAddress = "2001:0DB8:0:CD30:123:4567:89AB:CDEF"
        let subnetPrefix = "2001:0DB8:0:CD30::"

        // Both should parse successfully
        #expect(throws: Never.self, "Node address should parse successfully") {
            _ = try IPv6Address.parse(nodeAddress)
        }

        #expect(throws: Never.self, "Subnet prefix should parse successfully") {
            _ = try IPv6Address.parse(subnetPrefix)
        }

        // Verify that the subnet prefix is indeed a prefix of the node address
        let nodeBytes = try IPv6Address.parse(nodeAddress).bytes
        let subnetBytes = try IPv6Address.parse(subnetPrefix).bytes

        // Validate that node address has the subnet as a prefix (60-bit prefix = 7.5 bytes)
        let prefixLength = 60
        let hasValidPrefix = nodeBytes.hasPrefix(subnetBytes, upToBits: prefixLength)

        #expect(
            hasValidPrefix,
            "Node address should have subnet as a \(prefixLength)-bit prefix"
        )
    }

    // MARK: - RFC 4291 Section 2.2 Comprehensive Text Representation Tests

    @Test(
        "RFC 4291 Section 2.2 - Preferred form with all groups",
        arguments: [
            "2001:0db8:0000:0042:0000:8a2e:0370:7334",
            "ABCD:EF01:2345:6789:ABCD:EF01:2345:6789",
            "0000:0000:0000:0000:0000:0000:0000:0000",
            "FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF",
        ]
    )
    func testRFC4291Section22PreferredForm(testCase: String) throws {
        #expect(throws: Never.self, "Should parse preferred form: \(testCase)") {
            _ = try IPv6Address.parse(testCase)
        }
    }

    @Test(
        "RFC 4291 Section 2.2 - Leading zero omission in all positions",
        arguments: [
            ("2001:0db8:0000:0042:0000:8a2e:0370:7334", "2001:db8:0:42:0:8a2e:370:7334"),
            ("0001:0002:0003:0004:0005:0006:0007:0008", "1:2:3:4:5:6:7:8"),
            ("0000:0001:0002:0003:0004:0005:0006:0007", "0:1:2:3:4:5:6:7"),
            ("1000:0100:0010:0001:1000:0100:0010:0001", "1000:100:10:1:1000:100:10:1"),
        ]
    )
    func testRFC4291Section22LeadingZeroOmission(full: String, compressed: String) throws {
        let fullBytes = try IPv6Address.parse(full).bytes
        let compressedBytes = try IPv6Address.parse(compressed).bytes
        #expect(fullBytes == compressedBytes, "'\(full)' should equal '\(compressed)'")
    }

    @Test(
        "RFC 4291 Section 2.2 - Zero compression at beginning",
        arguments: [
            ("::", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            ("::1", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
            ("::8a2e:370:7334", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x8a, 0x2e, 0x03, 0x70, 0x73, 0x34]),
        ]
    )
    func testRFC4291Section22ZeroCompressionAtBeginning(compressed: String, expected: [UInt8]) throws {
        let parsed = try IPv6Address.parse(compressed)
        #expect(parsed.bytes == expected, "'\(compressed)' should parse correctly")
    }

    @Test(
        "RFC 4291 Section 2.2 - Zero compression in middle",
        arguments: [
            ("2001:db8::8a2e:370:7334", "2001:db8:0:0:0:8a2e:370:7334"),
            ("2001:db8::1", "2001:db8:0:0:0:0:0:1"),
            ("fe80::1", "fe80:0:0:0:0:0:0:1"),
            ("2001:0db8:0:0::1", "2001:db8:0:0:0:0:0:1"),
        ]
    )
    func testRFC4291Section22ZeroCompressionInMiddle(compressed: String, full: String) throws {
        let compressedBytes = try IPv6Address.parse(compressed).bytes
        let fullBytes = try IPv6Address.parse(full).bytes
        #expect(compressedBytes == fullBytes, "'\(compressed)' should equal '\(full)'")
    }

    @Test(
        "RFC 4291 Section 2.2 - Zero compression at end",
        arguments: [
            ("2001:db8::", "2001:db8:0:0:0:0:0:0"),
            ("2001:db8:0:0:1::", "2001:db8:0:0:1:0:0:0"),
            ("fe80::", "fe80:0:0:0:0:0:0:0"),
            ("1::", "1:0:0:0:0:0:0:0"),
        ]
    )
    func testRFC4291Section22ZeroCompressionAtEnd(compressed: String, full: String) throws {
        let compressedBytes = try IPv6Address.parse(compressed).bytes
        let fullBytes = try IPv6Address.parse(full).bytes
        #expect(compressedBytes == fullBytes, "'\(compressed)' should equal '\(full)'")
    }

    @Test(
        "RFC 4291 Section 2.2 - Multiple :: should fail",
        arguments: [
            "2001::db8::1",
            "::1::2",
            "fe80::1::2::3",
            "::1::",
        ]
    )
    func testRFC4291Section22MultipleDoubleColonsShouldFail(invalid: String) {
        #expect(throws: AddressError.self, "Multiple '::' should fail: \(invalid)") {
            _ = try IPv6Address.parse(invalid)
        }
    }

    @Test(
        "RFC 4291 Section 2.2 - Case insensitivity",
        arguments: [
            ("2001:db8::1", "2001:DB8::1", "2001:Db8::1"),
            ("dead:beef::cafe", "DEAD:BEEF::CAFE", "DeAd:BeEf::CaFe"),
            ("fe80::1", "FE80::1", "Fe80::1"),
            ("abcd:ef01:2345:6789::1", "ABCD:EF01:2345:6789::1", "AbCd:Ef01:2345:6789::1"),
        ]
    )
    func testRFC4291Section22CaseInsensitivity(lower: String, upper: String, mixed: String) throws {
        let lowerBytes = try IPv6Address.parse(lower).bytes
        let upperBytes = try IPv6Address.parse(upper).bytes
        let mixedBytes = try IPv6Address.parse(mixed).bytes

        #expect(lowerBytes == upperBytes, "Case should not matter: '\(lower)' vs '\(upper)'")
        #expect(lowerBytes == mixedBytes, "Case should not matter: '\(lower)' vs '\(mixed)'")
    }

    @Test("RFC 4291 Section 2.2 - Special addresses")
    func testRFC4291Section22SpecialAddresses() throws {
        // Unspecified address
        let unspecified = try IPv6Address.parse("::")
        #expect(unspecified.bytes.allSatisfy { $0 == 0 }, ":: should be all zeros")

        // Loopback address
        let loopback = try IPv6Address.parse("::1")
        let expectedLoopback: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        #expect(loopback.bytes == expectedLoopback, "::1 should be loopback address")

        // IPv4-compatible (deprecated but valid syntax)
        let ipv4Compat = try IPv6Address.parse("::c000:0201")
        let expectedCompat: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xc0, 0x00, 0x02, 0x01]
        #expect(ipv4Compat.bytes == expectedCompat, "::c000:0201 should parse correctly")
    }

    @Test(
        "RFC 4291 Section 2.2 - Invalid formats should fail",
        arguments: [
            "2001:db8",  // Too few groups without ::
            "2001:db8:1:2:3:4:5:6:7",  // Too many groups
            "2001:db8:1:2:3:4:5:6:7:8:9",  // Too many groups
            "2001:db8:::1",  // Triple colon
            "2001:db8::1::2",  // Multiple ::
            "gggg::1",  // Invalid hex character
            "2001:db8:xyz::1",  // Invalid hex character
            "::ffff:",  // Trailing colon
            ":2001:db8::1",  // Leading single colon
            "2001:db8::1:",  // Trailing single colon
        ]
    )
    func testRFC4291Section22InvalidFormatsShouldFail(invalid: String) {
        #expect(throws: AddressError.self, "Invalid format should fail: \(invalid)") {
            _ = try IPv6Address.parse(invalid)
        }
    }

    @Test("RFC 4291 Section 2.2 - Maximum values")
    func testRFC4291Section22MaximumValues() throws {
        // All FFs - maximum value
        let maxAddress = try IPv6Address.parse("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")
        #expect(maxAddress.bytes.allSatisfy { $0 == 0xFF }, "All groups should be 0xFFFF")

        // Mix of max and min values
        let mixedMax = try IPv6Address.parse("ffff:0:ffff:0:ffff:0:ffff:0")
        let expectedMixed: [UInt8] = [0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0, 0]
        #expect(mixedMax.bytes == expectedMixed, "Should alternate between max and zero")
    }

    @Test(
        "RFC 4291 Section 2.2 - Single zero groups",
        arguments: [
            ("2001:db8:0:1:2:3:4:5", "2001:db8:0:1:2:3:4:5"),  // Single 0, no compression needed
            ("2001:db8:0:0:1:2:3:4", "2001:db8::1:2:3:4"),  // Two zeros can be compressed
            ("0:0:0:0:0:0:0:1", "::1"),  // All zeros except last
        ]
    )
    func testRFC4291Section22SingleZeroGroups(withZero: String, withCompression: String) throws {
        let zeroBytes = try IPv6Address.parse(withZero).bytes
        let compressedBytes = try IPv6Address.parse(withCompression).bytes
        #expect(zeroBytes == compressedBytes, "'\(withZero)' should equal '\(withCompression)'")
    }

    @Test("RFC 4291 Section 2.2 - Boundary conditions")
    func testRFC4291Section22BoundaryConditions() throws {
        // Single non-zero value in each position
        for position in 0..<8 {
            var groups = [String](repeating: "0", count: 8)
            groups[position] = "1"
            let address = groups.joined(separator: ":")

            #expect(throws: Never.self, "Single non-zero at position \(position) should parse") {
                _ = try IPv6Address.parse(address)
            }
        }

        // Verify the bytes are correct
        let firstPosition = try IPv6Address.parse("1:0:0:0:0:0:0:0")
        #expect(firstPosition.bytes[0] == 0 && firstPosition.bytes[1] == 1, "First group should be 0x0001")

        let lastPosition = try IPv6Address.parse("0:0:0:0:0:0:0:1")
        #expect(lastPosition.bytes[14] == 0 && lastPosition.bytes[15] == 1, "Last group should be 0x0001")
    }

    @Test(
        "RFC 4291 Section 2.2 - Hex digit limits",
        arguments: [
            ("1:2:3:4:5:6:7:8", "1-digit groups"),
            ("12:34:56:78:9a:bc:de:f0", "2-digit groups"),
            ("123:456:789:abc:def:123:456:789", "3-digit groups"),
            ("1234:5678:9abc:def0:1234:5678:9abc:def0", "4-digit groups"),
            ("1:12:123:1234:1:12:123:1234", "Mixed digit counts"),
        ]
    )
    func testRFC4291Section22HexDigitLimits(address: String, description: String) throws {
        #expect(throws: Never.self, "Should parse \(description): \(address)") {
            _ = try IPv6Address.parse(address)
        }
    }

    @Test("RFC 4291 Section 2.2 - Equivalence of different representations")
    func testRFC4291Section22EquivalenceOfRepresentations() throws {
        let equivalentGroups: [[String]] = [
            // Same address, different representations
            [
                "2001:0db8:0000:0000:0000:0000:0000:0001",
                "2001:db8:0:0:0:0:0:1",
                "2001:db8::1",
                "2001:0DB8::1",
                "2001:0DB8:0000:0000:0000:0000:0000:0001",
            ],
            [
                "fe80:0000:0000:0000:0000:0000:0000:0001",
                "fe80::1",
                "FE80::1",
                "fe80:0:0:0:0:0:0:1",
            ],
            [
                "0000:0000:0000:0000:0000:0000:0000:0000",
                "::",
                "0:0:0:0:0:0:0:0",
            ],
        ]

        for group in equivalentGroups {
            let bytesArray = try group.map { try IPv6Address.parse($0).bytes }
            let firstBytes = bytesArray[0]

            for (index, bytes) in bytesArray.enumerated() {
                #expect(bytes == firstBytes, "All forms should be equivalent: \(group[index])")
            }
        }
    }

    @Test(
        "RFC 4291 Section 2.2 - Zero compression selection (longest run)",
        arguments: [
            ("2001:db8:0:0:1:0:0:1", "Two runs of 2 zeros each"),
            ("2001:0:0:0:db8:0:0:1", "Run of 3 and run of 2"),
            ("2001:db8:0:0:0:0:1:1", "Run of 4 zeros in middle"),
        ]
    )
    func testRFC4291Section22ZeroCompressionLongestRun(address: String, description: String) throws {
        #expect(throws: Never.self, "Should parse \(description): \(address)") {
            _ = try IPv6Address.parse(address)
        }
    }

    @Test(
        "RFC 4291 Section 2.2 - Edge case with :: at different positions",
        arguments: [
            ("::1", "0:0:0:0:0:0:0:1"),
            ("1::", "1:0:0:0:0:0:0:0"),
            ("1::1", "1:0:0:0:0:0:0:1"),
            ("1:2::1", "1:2:0:0:0:0:0:1"),
            ("1::2:3", "1:0:0:0:0:0:2:3"),
            ("1:2:3::4:5:6", "1:2:3:0:0:4:5:6"),
        ]
    )
    func testRFC4291Section22DoubleColonAtDifferentPositions(compressed: String, expanded: String) throws {
        let compressedBytes = try IPv6Address.parse(compressed).bytes
        let expandedBytes = try IPv6Address.parse(expanded).bytes
        #expect(compressedBytes == expandedBytes, "'\(compressed)' should equal '\(expanded)'")
    }

    // MARK: - RFC 4291 Section 2.2 IPv4 Mixed Notation Tests

    @Test(
        "RFC 4291 Section 2.2 - IPv4 mixed notation basic formats",
        arguments: [
            // RFC 4291 examples
            ("0:0:0:0:0:0:13.1.68.3", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13, 1, 68, 3]),
            ("::13.1.68.3", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13, 1, 68, 3]),

            // IPv4-mapped IPv6 address (::ffff:x.x.x.x)
            ("::ffff:129.144.52.38", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 129, 144, 52, 38]),
            ("0:0:0:0:0:ffff:129.144.52.38", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 129, 144, 52, 38]),

            // IPv4-compatible IPv6 address (deprecated but valid syntax)
            ("::192.168.1.1", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 192, 168, 1, 1]),
            ("::0.0.0.1", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),

            // Various valid positions
            ("2001:db8::192.0.2.1", [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 192, 0, 2, 1]),
            ("fe80::192.168.1.1", [0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 192, 168, 1, 1]),
        ]
    )
    func testRFC4291Section22IPv4MixedNotation(address: String, expected: [UInt8]) throws {
        let parsed = try IPv6Address.parse(address)
        #expect(parsed.bytes == expected, "IPv4 mixed notation '\(address)' should parse correctly")
    }

    @Test(
        "RFC 4291 Section 2.2 - IPv4 mixed notation with full IPv6 prefix",
        arguments: [
            ("0:0:0:0:0:0:192.168.1.1", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 192, 168, 1, 1]),
            ("2001:db8:0:0:0:0:192.0.2.1", [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 192, 0, 2, 1]),
            ("64:ff9b::192.0.2.33", [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 192, 0, 2, 33]),
        ]
    )
    func testRFC4291Section22IPv4MixedNotationFullPrefix(address: String, expected: [UInt8]) throws {
        let parsed = try IPv6Address.parse(address)
        #expect(parsed.bytes == expected, "Full prefix with IPv4 '\(address)' should parse correctly")
    }

    @Test("RFC 4291 Section 2.2 - IPv4 mixed notation edge cases")
    func testRFC4291Section22IPv4MixedNotationEdgeCases() throws {
        // Maximum values
        let maxIPv4 = try IPv6Address.parse("::255.255.255.255")
        let expectedMax: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255]
        #expect(maxIPv4.bytes == expectedMax, "Maximum IPv4 values should work")

        // Minimum values
        let minIPv4 = try IPv6Address.parse("::0.0.0.0")
        let expectedMin: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(minIPv4.bytes == expectedMin, "Minimum IPv4 values should work")

        // With non-zero prefix
        let withPrefix = try IPv6Address.parse("2001:db8:85a3::8a2e:255.255.255.255")
        let expectedPrefix: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0x85, 0xa3, 0, 0, 0, 0, 0x8a, 0x2e, 255, 255, 255, 255]
        #expect(withPrefix.bytes == expectedPrefix, "IPv4 with hex prefix should work")
    }

    @Test(
        "RFC 4291 Section 2.2 - IPv4 mixed notation invalid formats",
        arguments: [
            "::192.168.1",  // Incomplete IPv4
            "::192.168.1.1.1",  // Too many IPv4 octets
            "::256.1.1.1",  // IPv4 octet out of range
            "::192.168.001.1",  // Leading zeros in IPv4
            "::192.168.-1.1",  // Negative in IPv4
            "::192.168.1.a",  // Non-numeric in IPv4
            "2001:db8:1:2:3:4:5:192.168.1.1",  // Too many hex groups before IPv4
            "::192.168.1.1:1234",  // Extra hex after IPv4
        ]
    )
    func testRFC4291Section22IPv4MixedNotationInvalid(invalid: String) {
        #expect(throws: AddressError.self, "Invalid IPv4 mixed notation should fail: \(invalid)") {
            _ = try IPv6Address.parse(invalid)
        }
    }

    @Test("RFC 4291 Section 2.2 - IPv4 mixed notation equivalence")
    func testRFC4291Section22IPv4MixedNotationEquivalence() throws {
        // These should all represent the same address
        let equivalentForms = [
            "0:0:0:0:0:0:192.0.2.1",
            "::192.0.2.1",
            "::c000:201",  // Same as 192.0.2.1 in hex
        ]

        let bytesArray = try equivalentForms.map { try IPv6Address.parse($0).bytes }
        let firstBytes = bytesArray[0]

        for (index, bytes) in bytesArray.enumerated() {
            #expect(bytes == firstBytes, "All forms should be equivalent: \(equivalentForms[index])")
        }
    }

    @Test(
        "RFC 4291 Section 2.2 - IPv4-mapped IPv6 addresses",
        arguments: [
            ("127.0.0.1", "::ffff:127.0.0.1"),
            ("192.168.1.1", "::ffff:192.168.1.1"),
            ("8.8.8.8", "::ffff:8.8.8.8"),
            ("0.0.0.0", "::ffff:0.0.0.0"),
            ("255.255.255.255", "::ffff:255.255.255.255"),
        ]
    )
    func testRFC4291Section22IPv4MappedAddresses(ipv4: String, ipv6: String) throws {
        let parsed = try IPv6Address.parse(ipv6)

        // First 10 bytes should be 0
        #expect(parsed.bytes[0..<10].allSatisfy { $0 == 0 }, "First 10 bytes should be zero")

        // Next 2 bytes should be 0xff
        #expect(parsed.bytes[10] == 0xff && parsed.bytes[11] == 0xff, "Bytes 10-11 should be 0xffff")

        // Last 4 bytes should match IPv4 address
        let ipv4Parsed = try IPv4Address.parse(ipv4)
        let ipv4Bytes = [
            UInt8((ipv4Parsed >> 24) & 0xFF),
            UInt8((ipv4Parsed >> 16) & 0xFF),
            UInt8((ipv4Parsed >> 8) & 0xFF),
            UInt8(ipv4Parsed & 0xFF),
        ]
        #expect(Array(parsed.bytes[12..<16]) == ipv4Bytes, "Last 4 bytes should match IPv4")
    }

    @Test(
        "RFC 4291 Section 2.2 - IPv4 mixed notation with zone identifier",
        arguments: [
            "::ffff:192.168.1.1%eth0",
            "fe80::192.168.1.1%lo0",
        ]
    )
    func testRFC4291Section22IPv4MixedNotationWithZone(testCase: String) throws {
        #expect(throws: Never.self, "IPv4 mixed notation with zone should parse: \(testCase)") {
            let parsed = try IPv6Address.parse(testCase)
            #expect(parsed.zone != nil, "Zone should be preserved")
        }
    }
}

// MARK: - Array Extension for Prefix Validation

extension Array where Element == UInt8 {
    /// Checks if this byte array has another array as a prefix up to the specified number of bits
    /// - Parameters:
    ///   - prefix: The potential prefix array
    ///   - bits: Number of bits to compare (0-128 for IPv6)
    /// - Returns: true if the prefix matches for the specified number of bits
    func hasPrefix(_ prefix: [UInt8], upToBits bits: Int) -> Bool {
        guard self.count >= 16 && prefix.count >= 16 else { return false }
        guard bits >= 0 && bits <= 128 else { return false }

        let fullBytes = bits / 8
        let remainingBits = bits % 8

        // Compare full bytes
        for i in 0..<fullBytes {
            if self[i] != prefix[i] {
                return false
            }
        }

        // Compare partial byte if needed
        if remainingBits > 0 && fullBytes < 16 {
            let shiftAmount = 8 - remainingBits
            let mask: UInt8 = shiftAmount >= 8 ? 0 : (0xFF << shiftAmount)
            return (self[fullBytes] & mask) == (prefix[fullBytes] & mask)
        }

        return true
    }
}
