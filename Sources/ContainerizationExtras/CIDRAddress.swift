//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

/// Represents an IPv4 CIDR (Classless Inter-Domain Routing) address block.
///
/// A CIDR block defines a range of IP addresses using a base address and a prefix length.
/// This struct provides functionality for subnet calculations, address containment checks,
/// and network overlap detection.
///
/// ## Example usage:
/// ```swift
/// // Create from CIDR notation
/// let cidr = try CIDRAddress("192.168.1.0/24")
/// print(cidr.lower)  // 192.168.1.0
/// print(cidr.upper)  // 192.168.1.255
///
/// // Check if an address is in the block
/// let testAddr = try IPv4Address("192.168.1.100")
/// print(cidr.contains(ipv4: testAddr)) // true
///
/// // Get address index within the block
/// if let index = cidr.getIndex(testAddr) {
///     print("Address index: \(index)") // 100
/// }
/// ```
public struct CIDRAddress: CustomStringConvertible, Equatable, Sendable {

    /// The base (network) IPv4 address of the CIDR block.
    /// This is the lowest address in the range with all host bits set to 0.
    public let lower: IPv4Address

    /// The broadcast IPv4 address of the CIDR block.
    /// This is the highest address in the range with all host bits set to 1.
    public let upper: IPv4Address

    /// The IPv4 address component used to create this CIDR block.
    /// This may be any address within the block, not necessarily the network address.
    public let address: IPv4Address

    /// The prefix length (subnet mask) for the CIDR block, which determines its size.
    /// Valid range is 0-32, where 32 represents a single host and 0 represents all IPv4 addresses.
    public let prefixLength: PrefixLength

    /// Create a CIDR address block from its text representation.
    ///
    /// - Parameter cidr: A string in CIDR notation (e.g., "192.168.1.0/24")
    /// - Throws: `NetworkAddressError.invalidCIDR` if the format is invalid
    ///
    /// ## Example:
    /// ```swift
    /// let cidr = try CIDRAddress("10.0.0.0/8")   // 10.0.0.0 - 10.255.255.255
    /// let host = try CIDRAddress("192.168.1.1/32") // Single host
    /// ```
    public init(_ cidr: String) throws {
        let split = cidr.components(separatedBy: "/")
        guard split.count == 2 else {
            throw NetworkAddressError.invalidCIDR(cidr: cidr)
        }
        address = try IPv4Address(split[0])
        guard let prefixLength = PrefixLength(split[1]) else {
            throw NetworkAddressError.invalidCIDR(cidr: cidr)
        }
        guard prefixLength >= 0 && prefixLength <= 32 else {
            throw NetworkAddressError.invalidCIDR(cidr: cidr)
        }

        self.prefixLength = prefixLength
        lower = address.prefix(prefixLength: prefixLength)
        upper = IPv4Address(fromValue: lower.value + prefixLength.suffixMask32)
    }

    /// Create a CIDR address block from an IP address and prefix length.
    ///
    /// - Parameters:
    ///   - address: Any IPv4 address within the desired network
    ///   - prefixLength: The subnet mask length (0-32)
    /// - Throws: `NetworkAddressError.invalidCIDR` if the prefix length is invalid
    ///
    /// ## Example:
    /// ```swift
    /// let addr = try IPv4Address("192.168.1.150")
    /// let cidr = try CIDRAddress(addr, prefixLength: 24)
    /// print(cidr.description) // "192.168.1.150/24"
    /// print(cidr.lower)       // "192.168.1.0"
    /// ```
    public init(_ address: IPv4Address, prefixLength: PrefixLength) throws {
        guard prefixLength >= 0 && prefixLength <= 32 else {
            throw NetworkAddressError.invalidCIDR(cidr: "\(address)/\(prefixLength)")
        }

        self.prefixLength = prefixLength
        self.address = address
        lower = address.prefix(prefixLength: prefixLength)
        upper = IPv4Address(fromValue: lower.value + prefixLength.suffixMask32)
    }

    /// Create the smallest CIDR block that encompasses the given address range.
    ///
    /// - Parameters:
    ///   - lower: The lowest IPv4 address that must be included
    ///   - upper: The highest IPv4 address that must be included
    /// - Throws: `NetworkAddressError.invalidAddressRange` if lower > upper
    ///
    /// This initializer finds the minimal prefix length that creates a CIDR block
    /// containing both the lower and upper addresses.
    ///
    /// ## Example:
    /// ```swift
    /// let start = try IPv4Address("192.168.1.100")
    /// let end = try IPv4Address("192.168.1.200")
    /// let cidr = try CIDRAddress(lower: start, upper: end)
    /// // Results in a block that contains both addresses
    /// ```
    public init(lower: IPv4Address, upper: IPv4Address) throws {
        guard lower.value <= upper.value else {
            throw NetworkAddressError.invalidAddressRange(lower: lower.description, upper: upper.description)
        }

        address = lower
        for prefixLength: PrefixLength in 1...32 {
            // find the first case where a subnet mask would put lower and upper in different CIDR block
            let mask = prefixLength.prefixMask32

            if (lower.value & mask) != (upper.value & mask) {
                self.prefixLength = prefixLength - 1
                self.lower = address.prefix(prefixLength: self.prefixLength)
                self.upper = IPv4Address(fromValue: self.lower.value + self.prefixLength.suffixMask32)
                return
            }
        }

        // if lower and upper are same, create a /32 block
        self.prefixLength = 32
        self.lower = lower
        self.upper = upper
    }

    /// Get the zero-based index of the specified address within this CIDR block.
    ///
    /// - Parameter address: The IPv4 address to find the index for
    /// - Returns: The index of the address within the block, or `nil` if not contained
    ///
    /// The index represents the offset from the network base address (lower bound).
    /// This is useful for address allocation and iteration within a subnet.
    ///
    /// ## Example:
    /// ```swift
    /// let cidr = try CIDRAddress("192.168.1.0/24")
    /// let addr = try IPv4Address("192.168.1.10")
    /// if let index = cidr.getIndex(addr) {
    ///     print("Address index: \(index)") // 10
    /// }
    ///
    /// let outOfRange = try IPv4Address("192.168.2.1")
    /// print(cidr.getIndex(outOfRange)) // nil
    /// ```
    public func getIndex(_ address: IPv4Address) -> UInt32? {
        guard address.value >= lower.value && address.value <= upper.value else {
            return nil
        }

        return address.value - lower.value
    }

    /// Check if the CIDR block contains the specified IPv4 address.
    ///
    /// - Parameter ipv4: The IPv4 address to test for containment
    /// - Returns: `true` if the address is within this CIDR block's range
    ///
    /// ## Example:
    /// ```swift
    /// let cidr = try CIDRAddress("10.0.0.0/8")
    /// print(cidr.contains(ipv4: try IPv4Address("10.5.1.1")))   // true
    /// print(cidr.contains(ipv4: try IPv4Address("192.168.1.1"))) // false
    /// ```
    public func contains(ipv4: IPv4Address) -> Bool {
        lower.value <= ipv4.value && ipv4.value <= upper.value
    }

    /// Check if this CIDR block completely contains another CIDR block.
    ///
    /// - Parameter cidr: The other CIDR block to test for containment
    /// - Returns: `true` if the other block is entirely within this block
    ///
    /// ## Example:
    /// ```swift
    /// let large = try CIDRAddress("192.168.0.0/16")  // /16 network
    /// let small = try CIDRAddress("192.168.1.0/24")  // /24 subnet
    /// print(large.contains(cidr: small)) // true
    /// print(small.contains(cidr: large)) // false
    /// ```
    public func contains(cidr: CIDRAddress) -> Bool {
        lower.value <= cidr.lower.value && cidr.upper.value <= upper.value
    }

    /// Check if this CIDR block shares any addresses with another CIDR block.
    ///
    /// - Parameter cidr: The other CIDR block to test for overlap
    /// - Returns: `true` if the blocks have any addresses in common
    ///
    /// This method detects any form of overlap: partial overlap, complete containment,
    /// or identical ranges.
    ///
    /// ## Example:
    /// ```swift
    /// let cidr1 = try CIDRAddress("192.168.1.0/24")
    /// let cidr2 = try CIDRAddress("192.168.1.128/25")
    /// let cidr3 = try CIDRAddress("192.168.2.0/24")
    ///
    /// print(cidr1.overlaps(cidr: cidr2)) // true (cidr2 is subset)
    /// print(cidr1.overlaps(cidr: cidr3)) // false (different networks)
    /// ```
    public func overlaps(cidr: CIDRAddress) -> Bool {
        (lower.value <= cidr.lower.value && upper.value >= cidr.lower.value)
            || (upper.value >= cidr.upper.value && lower.value <= cidr.upper.value)
    }

    /// Returns the text representation of the CIDR block in standard notation.
    ///
    /// The format is "address/prefix_length" where address is the original address
    /// used to create the block (not necessarily the network address).
    public var description: String {
        "\(address)/\(prefixLength)"
    }
}

// MARK: - Codable Conformance
extension CIDRAddress: Codable {
    /// Creates a CIDRAddress from a JSON string representation.
    ///
    /// - Parameter decoder: The decoder to read data from
    /// - Throws: `DecodingError` if the string is not valid CIDR notation
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        try self.init(text)
    }

    /// Encodes the CIDRAddress as a JSON string in CIDR notation.
    ///
    /// - Parameter encoder: The encoder to write data to
    /// - Throws: `EncodingError` if encoding fails
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }
}
