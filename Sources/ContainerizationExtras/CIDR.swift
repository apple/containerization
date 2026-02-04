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
public enum CIDR: CustomStringConvertible, Equatable, Sendable, Hashable {

    case v4(IPv4Address, Prefix)
    case v6(IPv6Address, Prefix)

    /// Create a CIDR address block.
    public init(_ cidr: String) throws {
        if let cidrV4 = try? CIDRv4(cidr) {
            self = .v4(cidrV4.address, cidrV4.prefix)
        } else if let cidrV6 = try? CIDRv6(cidr) {
            self = .v6(cidrV6.address, cidrV6.prefix)
        } else {
            throw Error.invalidCIDR(cidr: cidr)
        }
    }

    /// Create a CIDR address from a member IP and a prefix length.
    public init(_ address: IPAddress, prefix: Prefix) throws {
        switch address {
        case .v4(let addr):
            guard prefix.length <= 32 else {
                throw Error.invalidCIDR(cidr: "\(address)/\(prefix)")
            }
            self = .v4(addr, prefix)
        case .v6(let addr):
            guard prefix.length <= 128 else {
                throw Error.invalidCIDR(cidr: "\(address)/\(prefix)")
            }
            self = .v6(addr, prefix)
        }
    }

    /// Create the smallest CIDR block that includes the lower and upper bounds.
    ///
    /// For type-safe construction, prefer `v4Range(lower:upper:)` or `v6Range(lower:upper:)`.
    public init(lower: IPAddress, upper: IPAddress) throws {
        switch (lower, upper) {
        case (.v4(let lowerAddr), .v4(let upperAddr)):
            let cidr = try CIDRv4(lower: lowerAddr, upper: upperAddr)
            self = .v4(cidr.address, cidr.prefix)
        case (.v6(let lowerAddr), .v6(let upperAddr)):
            let cidr = try CIDRv6(lower: lowerAddr, upper: upperAddr)
            self = .v6(cidr.address, cidr.prefix)
        default:
            throw Error.invalidAddressRange(lower: lower.description, upper: upper.description)
        }
    }

    /// The IP component of this CIDR address.
    @inlinable
    public var address: IPAddress {
        switch self {
        case .v4(let addr, _):
            return .v4(addr)
        case .v6(let addr, _):
            return .v6(addr)
        }
    }

    /// The prefix length of this CIDR address.
    @inlinable
    public var prefix: Prefix {
        switch self {
        case .v4(_, let prefix), .v6(_, let prefix):
            return prefix
        }
    }

    /// The lowest address in this CIDR block
    @inlinable
    public var lower: IPAddress {
        switch self {
        case (.v4(let addr, let prefix)):
            return .v4(IPv4Address(addr.value & prefix.prefixMask32))
        case (.v6(let addr, let prefix)):
            return .v6(IPv6Address(addr.value & prefix.prefixMask128))
        }
    }

    /// The highest address in this CIDR block (broadcast address).
    @inlinable
    public var upper: IPAddress {
        switch self {
        case .v4(let addr, let prefix):
            return .v4(IPv4Address(addr.value | prefix.suffixMask32))
        case .v6(let addr, let prefix):
            return .v6(IPv6Address(addr.value | prefix.suffixMask128, zone: addr.zone))
        }
    }

    /// Return true if the CIDR block contains the specified address.
    ///
    /// Compares network portion of the given IP address.
    @inlinable
    public func contains(_ ip: IPAddress) -> Bool {
        switch (self, ip) {
        case (.v4(let network, let prefix), .v4(let ip)):
            return network.value == (ip.value & prefix.prefixMask32)
        case (.v6(let network, let prefix), .v6(let ip)):
            return (network.zone == ip.zone) && (network.value == (ip.value & prefix.prefixMask128))
        default:
            return false
        }
    }

    /// Retrieve the text representation of the CIDR block.
    public var description: String {
        "\(address)/\(prefix)"
    }
}

extension CIDR {
    public enum Error: Swift.Error {
        case invalidCIDR(cidr: String)
        case invalidAddressRange(lower: String, upper: String)
    }
}

extension CIDR: Codable {
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
