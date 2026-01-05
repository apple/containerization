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

/// Represents an IPv6 network address conforming to RFC 5952 and RFC 4291.
public struct IPv6Address: Sendable, Hashable, CustomStringConvertible, Equatable, Comparable {
    public let value: UInt128

    public let zone: String?

    /// Creates an IPv6Address by parsing a string representation.
    ///
    /// Supports standard IPv6 formats including compressed notation (::), mixed IPv4 notation, and zone identifiers.
    ///
    /// - Parameter address: String representation of an IPv6 address
    /// - Throws: `AddressError` if the string is not a valid IPv6 address
    public init(_ address: String) throws {
        self = try Self.parse(address)
    }

    /// Creates an IPv6Address from 16 bytes.
    ///
    /// - Parameters:
    ///   - bytes: 16-byte array representing the IPv6 address
    ///   - zone: Optional zone identifier (e.g., "eth0")
    @inlinable
    public init(_ bytes: [UInt8], zone: String? = nil) {
        precondition(bytes.count == 16, "IPv6 address must be exactly 16 bytes")

        // Build UInt128 value in chunks to avoid compiler complexity
        let hh =
            (UInt128(bytes[0]) << 120) | (UInt128(bytes[1]) << 112) | (UInt128(bytes[2]) << 104)
            | (UInt128(bytes[3]) << 96)
        let hl =
            (UInt128(bytes[4]) << 88) | (UInt128(bytes[5]) << 80) | (UInt128(bytes[6]) << 72)
            | (UInt128(bytes[7]) << 64)
        let lh =
            (UInt128(bytes[8]) << 56) | (UInt128(bytes[9]) << 48) | (UInt128(bytes[10]) << 40)
            | (UInt128(bytes[11]) << 32)
        let ll =
            (UInt128(bytes[12]) << 24) | (UInt128(bytes[13]) << 16) | (UInt128(bytes[14]) << 8) | UInt128(bytes[15])

        self.value = hh | hl | lh | ll
        self.zone = zone
    }

    @inlinable
    public init(_ value: UInt128, zone: String? = nil) {
        self.value = value
        self.zone = zone
    }

    /// Canonical string representation following RFC 5952.
    public var description: String {
        // Convert UInt128 value to 16-bit groups
        let groups: [UInt16] = [
            UInt16((value >> 112) & 0xFFFF),
            UInt16((value >> 96) & 0xFFFF),
            UInt16((value >> 80) & 0xFFFF),
            UInt16((value >> 64) & 0xFFFF),
            UInt16((value >> 48) & 0xFFFF),
            UInt16((value >> 32) & 0xFFFF),
            UInt16((value >> 16) & 0xFFFF),
            UInt16(value & 0xFFFF),
        ]

        // Find the longest run of consecutive zeros for :: compression
        var longestZeroStart = -1
        var longestZeroLength = 0
        var currentZeroStart = -1
        var currentZeroLength = 0

        for (index, group) in groups.enumerated() {
            if group == 0 {
                if currentZeroStart == -1 {
                    currentZeroStart = index
                    currentZeroLength = 1
                } else {
                    currentZeroLength += 1
                }
            } else {
                if currentZeroLength > longestZeroLength {
                    longestZeroStart = currentZeroStart
                    longestZeroLength = currentZeroLength
                }
                currentZeroStart = -1
                currentZeroLength = 0
            }
        }
        if currentZeroLength > longestZeroLength {
            longestZeroStart = currentZeroStart
            longestZeroLength = currentZeroLength
        }

        let useCompression = longestZeroLength >= 2

        var result = ""
        var index = 0

        while index < 8 {
            if useCompression && index == longestZeroStart {
                if index == 0 {
                    result += "::"
                } else {
                    result += ":"
                }
                // Skip the compressed zeros
                index += longestZeroLength

                // If we compressed to the end, we're done
                if index >= 8 {
                    break
                }
            } else {
                // Add the group in lowercase hex without leading zeros
                result += String(groups[index], radix: 16, uppercase: false)
                index += 1

                // Add colon if not at the end
                if index < 8 {
                    result += ":"
                }
            }
        }

        if let zone = zone {
            result += "%" + zone
        }

        return result
    }

    @inlinable
    public var bytes: [UInt8] {
        Self.bytes(self.value)
    }

    @usableFromInline
    internal static func bytes(_ value: UInt128) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 16)
        result[0] = UInt8((value >> 120) & 0xff)
        result[1] = UInt8((value >> 112) & 0xff)
        result[2] = UInt8((value >> 104) & 0xff)
        result[3] = UInt8((value >> 96) & 0xff)
        result[4] = UInt8((value >> 88) & 0xff)
        result[5] = UInt8((value >> 80) & 0xff)
        result[6] = UInt8((value >> 72) & 0xff)
        result[7] = UInt8((value >> 64) & 0xff)
        result[8] = UInt8((value >> 56) & 0xff)
        result[9] = UInt8((value >> 48) & 0xff)
        result[10] = UInt8((value >> 40) & 0xff)
        result[11] = UInt8((value >> 32) & 0xff)
        result[12] = UInt8((value >> 24) & 0xff)
        result[13] = UInt8((value >> 16) & 0xff)
        result[14] = UInt8((value >> 8) & 0xff)
        result[15] = UInt8(value & 0xff)
        return result
    }

    @available(macOS 26.0, *)
    @usableFromInline
    internal static func bytes(_ value: UInt128) -> InlineArray<16, UInt8> {
        let result: InlineArray<16, UInt8> = [
            UInt8((value >> 120) & 0xff),
            UInt8((value >> 112) & 0xff),
            UInt8((value >> 104) & 0xff),
            UInt8((value >> 96) & 0xff),
            UInt8((value >> 88) & 0xff),
            UInt8((value >> 80) & 0xff),
            UInt8((value >> 72) & 0xff),
            UInt8((value >> 64) & 0xff),
            UInt8((value >> 56) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return result
    }

    /// The unspecified IPv6 address (::)
    public static let unspecified = IPv6Address(0)

    /// The loopback IPv6 address (::1)
    public static let loopback = IPv6Address(1)

    // MARK: - Address Classification Methods

    /// Returns `true` if this is the unspecified address (::).
    @inlinable
    public var isUnspecified: Bool {
        value == 0
    }

    /// Returns `true` if this is the loopback address (::1).
    @inlinable
    public var isLoopback: Bool {
        value == 1
    }

    /// Returns `true` if this is a multicast address (ff00::/8).
    @inlinable
    public var isMulticast: Bool {
        (value >> 120) == 0xFF
    }

    /// Returns `true` if this is a link-local unicast address (fe80::/10).
    @inlinable
    public var isLinkLocal: Bool {
        (value >> 118) == 0x3FA  // fe80::/10 = top 10 bits are 1111111010
    }

    /// Returns `true` if this is a unique local address (fc00::/7).
    @inlinable
    public var isUniqueLocal: Bool {
        (value >> 121) == 0x7E  // fc00::/7 = top 7 bits are 1111110
    }

    /// Returns `true` if this is a global unicast address.
    @inlinable
    public var isGlobalUnicast: Bool {
        !isUnspecified && !isLoopback && !isMulticast && !isLinkLocal && !isUniqueLocal
    }

    /// Returns `true` if this is a documentation address (2001:db8::/32).
    @inlinable
    public var isDocumentation: Bool {
        (value >> 96) == 0x2001_0DB8  // 2001:db8::/32
    }
    /// Compares two IPv6 addresses numerically, then by zone if values are equal.
    @inlinable
    public static func < (lhs: IPv6Address, rhs: IPv6Address) -> Bool {
        if lhs.value != rhs.value {
            return lhs.value < rhs.value
        }
        // Same value, compare zones lexicographically
        return (lhs.zone ?? "") < (rhs.zone ?? "")
    }
}

extension IPv6Address: Codable {
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
