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

@frozen
public struct IPv4Address: Sendable, Hashable, CustomStringConvertible, Equatable, Comparable {
    public let value: UInt32

    @inlinable
    public init(_ value: UInt32) {
        self.value = value
    }

    /// Creates an IPv4Address from a string representation.
    ///
    /// - Parameter string: The IPv4 address string in dotted decimal notation (e.g., "192.168.1.1")
    /// - Throws: `AddressError.unableToParse` if the string is not a valid IPv4 address
    @inlinable
    public init(_ string: String) throws {
        self.value = try Self.parse(string)
    }

    @inlinable
    public var bytes: [UInt8] {
        Self.bytes(value)
    }

    @usableFromInline
    static func bytes(_ value: UInt32) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        result[0] = UInt8((value >> 24) & 0xff)
        result[1] = UInt8((value >> 16) & 0xff)
        result[2] = UInt8((value >> 8) & 0xff)
        result[3] = UInt8(value & 0xff)
        return result
    }

    // TODO: spans?
    @available(macOS 26.0, *)
    @usableFromInline
    static func bytes(_ value: UInt32) -> InlineArray<4, UInt8> {
        let result: InlineArray<4, UInt8> = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return result
    }

    @inlinable
    public var description: String {
        "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
    }

    /// Parses an IPv4 address string in dotted decimal notation into a UInt32 representation.
    ///
    /// ## Validation Rules
    /// - Exactly 4 octets separated by dots
    /// - Each octet must be 0-255
    /// - No leading zeros (except for "0" itself)
    /// - No whitespace characters
    /// - Only digits and dots allowed
    ///
    /// ## Examples
    /// ```swift
    /// IPv4Address.parse("192.168.1.1")    // Returns: 3232235777
    /// IPv4Address.parse("127.0.0.1")      // Returns: 2130706433
    /// IPv4Address.parse("0.0.0.0")        // Returns: 0
    /// IPv4Address.parse("255.255.255.255") // Returns: 4294967295
    ///
    /// // Invalid examples:
    /// IPv4Address.parse("192.168.1")       // Wrong number of octets
    /// IPv4Address.parse("192.168.1.256")   // Octet out of range
    /// IPv4Address.parse("192.168.001.1")   // Leading zeros
    /// IPv4Address.parse(" 192.168.1.1 ")   // Whitespace
    /// ```
    ///
    /// - Parameter s: The IPv4 address string to parse
    /// - Returns: The 32-bit representation of the IP address, or `nil` if parsing fails
    /// - Note: The returned value is in network byte order (big-endian)
    @usableFromInline
    internal static func parse(_ s: String) throws -> UInt32 {
        guard !s.isEmpty, s.count >= 7, s.count <= 15 else {
            throw AddressError.unableToParse
        }

        // IP addresses should only contain ASCII digits and dots
        let utf8 = s.utf8
        for byte in utf8 {
            // ASCII whitespace: space(32), tab(9), newline(10), return(13)
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                throw AddressError.unableToParse
            }
        }

        // accumulator for the 32bit representation of the IPv4 address
        var result: UInt32 = 0

        // tracking octet count, max 4 allowed
        var octetCount = 0
        var currentOctet = 0

        // number of digits in the string representation of the octet, max 3
        var digitCount = 0

        for byte in utf8 {
            if byte == 46 {  // ASCII '.'
                // Validate octet before processing
                guard octetCount < 3, digitCount > 0, digitCount <= 3, currentOctet <= 255 else {
                    throw AddressError.unableToParse
                }

                // Shift result and add current octet
                result = (result << 8) | UInt32(currentOctet)

                // Reset for next octet
                octetCount += 1
                currentOctet = 0
                digitCount = 0

            } else if byte >= 48 && byte <= 57 {  // ASCII '0'-'9'
                let digit = Int(byte - 48)

                digitCount += 1

                // Check for invalid leading zeros: "01", "001", etc.
                // Allow single "0" but reject multi-digit numbers starting with 0
                if digitCount == 1 && digit == 0 {
                    // First digit is 0 - this is only valid if it's the only digit
                    currentOctet = 0
                } else if digitCount > 1 && currentOctet == 0 {
                    // We had a leading zero and now have more digits - invalid
                    throw AddressError.unableToParse
                } else {
                    // Normal case: build the octet value
                    currentOctet = currentOctet * 10 + digit
                }

                // Early termination if octet becomes too large
                guard currentOctet <= 255, digitCount <= 3 else {
                    throw AddressError.unableToParse
                }

            } else {
                throw AddressError.unableToParse
            }
        }

        // Validate final octet
        guard octetCount == 3, digitCount > 0, digitCount <= 3, currentOctet <= 255 else {
            throw AddressError.unableToParse
        }

        return (result << 8) | UInt32(currentOctet)
    }

    // MARK: - Address Classification Methods

    /// Returns `true` if this is the unspecified address (0.0.0.0).
    ///
    /// Per RFC 791, 0.0.0.0 is the "this network" address.
    @inlinable
    public var isUnspecified: Bool {
        value == 0
    }

    /// Returns `true` if this is a loopback address (127.0.0.0/8).
    ///
    /// Per RFC 1122 Section 3.2.1.3, the entire 127.0.0.0/8 block is reserved for loopback.
    @inlinable
    public var isLoopback: Bool {
        (value & 0xFF00_0000) == 0x7F00_0000
    }

    /// Returns `true` if this is a multicast address (224.0.0.0/4).
    ///
    /// Per RFC 1112, addresses in the range 224.0.0.0 to 239.255.255.255 are multicast addresses.
    @inlinable
    public var isMulticast: Bool {
        (value & 0xF000_0000) == 0xE000_0000
    }

    /// Returns `true` if this is a link-local address (169.254.0.0/16).
    ///
    /// Per RFC 3927, 169.254.0.0/16 is reserved for link-local addresses (APIPA/Auto-IP).
    @inlinable
    public var isLinkLocal: Bool {
        (value & 0xFFFF_0000) == 0xA9FE_0000
    }

    /// Returns `true` if this is the limited broadcast address (255.255.255.255).
    ///
    /// Per RFC 919/922, 255.255.255.255 is the limited broadcast address.
    @inlinable
    public var isBroadcast: Bool {
        value == 0xFFFF_FFFF
    }

    /// Compares two IPv4 addresses numerically.
    @inlinable
    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.value < rhs.value
    }
}

extension IPv4Address: Codable {
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
