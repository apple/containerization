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

/// Describes an IPv4 or IPv6 CIDR address block.
@frozen
public struct CIDRv6: CustomStringConvertible, Equatable, Sendable, Hashable {

    /// The IP component of this CIDR address.
    public let address: IPv6Address

    /// The prefix length of this CIDR address.
    public let prefix: Prefix

    /// Create a CIDR address block.
    public init(_ cidr: String) throws {
        let split = cidr.split(separator: "/")
        guard split.count == 2 else {
            throw CIDR.Error.invalidCIDR(cidr: cidr)
        }
        guard let prefixLength = UInt8(split[1]), let prefix = Prefix(length: prefixLength) else {
            throw CIDR.Error.invalidCIDR(cidr: cidr)
        }

        let address = try IPv6Address(String(split[0]))
        try self.init(address, prefix: prefix)
    }

    /// Create a CIDR address from a member IP and a prefix length.
    public init(_ address: IPv6Address, prefix: Prefix) throws {
        guard prefix.length <= 128 else {
            throw CIDR.Error.invalidCIDR(cidr: "\(address)/\(prefix)")
        }
        self.address = address
        self.prefix = prefix
    }

    /// Create the smallest IPv6 CIDR block that includes the lower and upper bounds.
    ///
    /// - Parameters:
    ///   - lower: The lower bound IPv6 address
    ///   - upper: The upper bound IPv6 address
    /// - Returns: The smallest CIDR block containing both addresses
    /// - Throws: If lower > upper or zones don't match
    public init(lower: IPv6Address, upper: IPv6Address) throws {
        guard lower.value <= upper.value && lower.zone == upper.zone else {
            throw CIDR.Error.invalidAddressRange(lower: lower.description, upper: upper.description)
        }

        for length in 1...128 {
            let prefixLength = Prefix(unchecked: UInt8(length))
            let mask = prefixLength.prefixMask128
            if (lower.value & mask) != (upper.value & mask) {
                let prefix = Prefix(unchecked: UInt8(length - 1))
                let networkAddr = IPv6Address(lower.value & prefix.prefixMask128, zone: lower.zone)
                try self.init(networkAddr, prefix: prefix)
                return
            }
        }
        // Same address - /128 block
        let prefix = Prefix(unchecked: 128)
        let networkAddr = IPv6Address(lower.value & prefix.prefixMask128, zone: lower.zone)
        try self.init(networkAddr, prefix: prefix)
    }

    /// The lowest address in this CIDR block
    @inlinable
    public var lower: IPv6Address {
        IPv6Address(address.value & prefix.prefixMask128)
    }

    /// The highest address in this CIDR block (broadcast address).
    @inlinable
    public var upper: IPv6Address {
        IPv6Address(address.value | prefix.suffixMask128, zone: address.zone)
    }

    /// Return true if the CIDR block contains the specified address.
    ///
    /// Compares network portion of the given IP address.
    @inlinable
    public func contains(_ ip: IPv6Address) -> Bool {
        (address.zone == ip.zone) && ((address.value & prefix.prefixMask128) == (ip.value & prefix.prefixMask128))
    }

    /// Retrieve the text representation of the CIDR block.
    public var description: String {
        "\(address)/\(prefix)"
    }
}

extension CIDRv6: Codable {
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
