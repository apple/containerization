//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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

/// Describes an IPv4 CIDR address block.
public struct CIDRAddress: CustomStringConvertible, Equatable, Sendable {

    /// The base IPv4 address of the CIDR block.
    public let lower: IPv4Address

    /// The last IPv4 address of the CIDR block
    public let upper: IPv4Address

    /// The IPv4 address component of the CIDR block.
    public let address: IPv4Address

    /// The address prefix length for the CIDR block, which determines its size.
    public let prefixLength: PrefixLength

    /// Create an CIDR address block from its text representation.
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

    /// Create a CIDR address from a member IP and a prefix length.
    public init(_ address: IPv4Address, prefixLength: PrefixLength) throws {
        guard prefixLength >= 0 && prefixLength <= 32 else {
            throw NetworkAddressError.invalidCIDR(cidr: "\(address)/\(prefixLength)")
        }

        self.prefixLength = prefixLength
        self.address = address
        lower = address.prefix(prefixLength: prefixLength)
        upper = IPv4Address(fromValue: lower.value + prefixLength.suffixMask32)
    }

    /// Create the smallest CIDR block that includes the lower and upper bounds.
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

    /// Get the offset of the specified address, relative to the
    /// base address for the CIDR block, returning nil if the block
    /// does not contain the address.
    public func getIndex(_ address: IPv4Address) -> UInt32? {
        guard address.value >= lower.value && address.value <= upper.value else {
            return nil
        }

        return address.value - lower.value
    }

    /// Return true if the CIDR block contains the specified address.
    public func contains(ipv4: IPv4Address) -> Bool {
        lower.value <= ipv4.value && ipv4.value <= upper.value
    }

    /// Return true if the CIDR block contains all addresses of another CIDR block.
    public func contains(cidr: CIDRAddress) -> Bool {
        lower.value <= cidr.lower.value && cidr.upper.value <= upper.value
    }

    /// Return true if the CIDR block shares any addresses with another CIDR block.
    public func overlaps(cidr: CIDRAddress) -> Bool {
        (lower.value <= cidr.lower.value && upper.value >= cidr.lower.value)
            || (upper.value >= cidr.upper.value && lower.value <= cidr.upper.value)
    }

    /// Retrieve the text representation of the CIDR block.
    public var description: String {
        "\(address)/\(prefixLength)"
    }
}

extension CIDRAddress: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        try self.init(text)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }
}
