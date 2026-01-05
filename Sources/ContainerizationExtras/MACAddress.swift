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

/// An EUI-48 MAC address as specified by IEEE 802.
@frozen
public struct MACAddress: Sendable, Hashable, CustomStringConvertible, Equatable, Comparable {
    public let value: UInt64

    /// Creates an MACAddress from an integer.
    ///
    /// - Parameter value: The big-endian value of the MAC address.
    ///   The most significant 16 bits of the value are ignored.
    @inlinable
    public init(_ value: UInt64) {
        self.value = value & 0x0000_ffff_ffff_ffff
    }

    /// Creates an MACAddress from a string representation.
    ///
    /// - Parameter string: The MAC address string with colon or dash delimiters.
    /// - Throws: `AddressError.unableToParse` if the string is not a valid MAC address
    @inlinable
    public init(_ string: String) throws {
        self.value = try Self.parse(string)
    }

    @inlinable
    public var bytes: [UInt8] {
        Self.bytes(value)
    }

    @usableFromInline
    static func bytes(_ value: UInt64) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 6)
        result[0] = UInt8((value >> 40) & 0xff)
        result[1] = UInt8((value >> 32) & 0xff)
        result[2] = UInt8((value >> 24) & 0xff)
        result[3] = UInt8((value >> 16) & 0xff)
        result[4] = UInt8((value >> 8) & 0xff)
        result[5] = UInt8(value & 0xff)
        return result
    }

    @available(macOS 26.0, *)
    @usableFromInline
    static func bytes(_ value: UInt64) -> InlineArray<6, UInt8> {
        let result: InlineArray<6, UInt8> = [
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return result
    }

    @inlinable
    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Parses an MAC address string into a UInt64 representation.
    ///
    /// ## Validation Rules
    /// - Exactly six groups of two hexadecimal digits, separated by colons
    ///   or dashes
    /// - No whitespace characters
    /// - Only hexadecimal digits and colons allowed
    ///
    /// ## Examples
    /// ```swift
    /// MACAddress.parse("01:23:45:67:89:ab") // Returns: 0x0000_0123_4567_89ab
    /// MACAddress.parse("01-23-45-67-89-AB") // Returns: 0x0000_0123_4567_89ab
    /// MACAddress.parse("00:00:00:00:00:00") // Returns: 0x0000_0000_0000_0000
    /// MACAddress.parse("ff:ff:ff:ff:ff:ff") // Returns: 0x0000_ffff_ffff_ffff
    ///
    /// // Invalid examples:
    /// MACAddress.parse("01:23:45:67:89")    // Wrong number of octets
    /// MACAddress.parse("01:23:45:67:89:a")  // Invalid octet length
    /// MACAddress.parse("01:23:45:67:89:hi") // Invalid octet content
    /// MACAddress.parse("01:23-45:67-89:ab") // Inconsistent separators
    /// MACAddress.parse(" 01:23:45:67:89:ab ") // Whitespace
    /// ```
    ///
    /// - Parameter s: The MAC address string to parse
    /// - Returns: The 64-bit representation of the IP address, or `nil` if parsing fails
    /// - Note: The returned value is in network byte order (big-endian)
    @usableFromInline
    internal static func parse(_ s: String) throws -> UInt64 {
        guard !s.isEmpty, s.count == 17 else {
            throw AddressError.unableToParse
        }

        // MAC addresses should only contain ASCII hex digits and dots
        let utf8 = s.utf8
        for byte in utf8 {
            // ASCII whitespace: space(32), tab(9), newline(10), return(13)
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                throw AddressError.unableToParse
            }
        }

        // accumulator for the 64 bit representation of the MAC address
        var result: UInt64 = 0

        // tracking octet count, max 6 allowed
        var octetCount = 0
        var currentOctet = 0

        // number of digits in the string representation of the octet
        var digitCount = 0

        // separator character to use
        var separator: String.UTF8View.Element?

        for byte in utf8 {
            if byte == 0x3a || byte == 0x2d {  // ASCII ':'
                // Ensure separator is consistent
                guard separator == nil || byte == separator else {
                    throw AddressError.unableToParse
                }
                separator = byte

                // Validate octet before processing
                guard octetCount < 5, digitCount == 2 else {
                    throw AddressError.unableToParse
                }

                // Shift result and add current octet
                result = (result << 8) | UInt64(currentOctet)

                // Reset for next octet
                octetCount += 1
                currentOctet = 0
                digitCount = 0

            } else if byte >= 0x30 && byte <= 0x39 {  // ASCII '0'-'9'
                let digit = Int(byte - 0x30)

                digitCount += 1
                currentOctet = (currentOctet << 4) + digit

                // Early termination if octet becomes too large
                guard digitCount <= 2 else {
                    throw AddressError.unableToParse
                }

            } else if byte >= 0x41 && byte <= 0x46 {  // ASCII 'A'-'F'
                let digit = Int(byte - 0x41 + 10)

                digitCount += 1
                currentOctet = (currentOctet << 4) + digit

                // Early termination if octet becomes too large
                guard digitCount <= 2 else {
                    throw AddressError.unableToParse
                }

            } else if byte >= 0x61 && byte <= 0x66 {  // ASCII 'A'-'F'
                let digit = Int(byte - 0x61 + 10)

                digitCount += 1
                currentOctet = (currentOctet << 4) + digit

                // Early termination if octet becomes too large
                guard digitCount <= 2 else {
                    throw AddressError.unableToParse
                }

            } else {
                throw AddressError.unableToParse
            }
        }

        // Validate final octet
        guard octetCount == 5, digitCount == 2 else {
            throw AddressError.unableToParse
        }

        return (result << 8) | UInt64(currentOctet)
    }

    // MARK: - Address Classification Methods

    /// Returns `true` if the MAC address is locally administered.
    ///
    /// IEEE 802 specifies that the second-least-significant bit of
    /// the first octet of the MAC address determines whether the
    /// address is globally unique (bit cleared) or locally
    /// administered (bit set).
    @inlinable
    public var isLocallyAdministered: Bool {
        (value & 0x0000_0200_0000_0000) != 0
    }

    /// Returns `true` if the MAC address is multicast.
    ///
    /// IEEE 802 specifies that the least-significant bit of
    /// the first octet of the MAC address determines whether the
    /// address is unicast (bit cleared) or multicast (bit set).
    @inlinable
    public var isMulticast: Bool {
        (value & 0x0000_0100_0000_0000) != 0
    }

    /// Returns the link local IP address based on the EUI-64 version
    /// of the MAC address.
    ///
    /// - Parameter network: The IPv6 address to use for the network prefix
    /// - Returns: The link local IP address for the MAC address
    @inlinable
    public func ipv6Address(network: IPv6Address) -> IPv6Address {
        let prefixBytes = network.bytes
        return IPv6Address([
            prefixBytes[0], prefixBytes[1], prefixBytes[2], prefixBytes[3],
            prefixBytes[4], prefixBytes[5], prefixBytes[6], prefixBytes[7],
            bytes[0] ^ 0x02, bytes[1], bytes[2], 0xff,
            0xfe, bytes[3], bytes[4], bytes[5],
        ])
    }

    /// Compares two IPv4 addresses numerically.
    @inlinable
    public static func < (lhs: MACAddress, rhs: MACAddress) -> Bool {
        lhs.value < rhs.value
    }
}

extension MACAddress: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        try self.init(string)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
