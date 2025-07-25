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

/// Errors related to IP and CIDR addresses.
public enum NetworkAddressError: Swift.Error, Equatable, CustomStringConvertible {
    case invalidStringAddress(address: String)
    case invalidNetworkByteAddress(address: [UInt8])
    case invalidCIDR(cidr: String)
    case invalidAddressForSubnet(address: String, cidr: String)
    case invalidAddressRange(lower: String, upper: String)

    /// Provides detailed, actionable error descriptions to help developers fix validation issues.
    public var description: String {
        switch self {
        case .invalidStringAddress(let address):
            return "Invalid IPv4 address format '\(address)'. Expected dotted-decimal notation with 4 octets (0-255) separated by dots, such as '192.168.1.1' or '10.0.0.255'."
        case .invalidNetworkByteAddress(let address):
            return "Invalid IPv4 address bytes \(address). Expected exactly 4 bytes with values in range 0-255, such as [192, 168, 1, 1]."
        case .invalidCIDR(let cidr):
            return "Invalid CIDR block '\(cidr)'. Expected format 'x.x.x.x/n' where x.x.x.x is a valid IPv4 address and n is a prefix length from 0-32, such as '192.168.1.0/24' or '10.0.0.0/8'."
        case .invalidAddressForSubnet(let address, let cidr):
            return "Invalid address '\(address)' for subnet '\(cidr)'. The address must be within the network range defined by the CIDR block."
        case .invalidAddressRange(let lower, let upper):
            return "Invalid address range from '\(lower)' to '\(upper)'. The lower bound must be less than or equal to the upper bound, and both must be valid IPv4 addresses."
        }
    }
}

/// Type alias for network prefix lengths (0-32 for IPv4, 0-48 for truncated IPv6).
public typealias PrefixLength = UInt8

extension PrefixLength {
    /// Compute a bit mask that passes the suffix bits, given the network prefix mask length.
    /// 
    /// For IPv4 addresses, this calculates the host portion mask.
    /// - Returns: A 32-bit mask where host bits are set to 1
    public var suffixMask32: UInt32 {
        if self <= 0 {
            return 0xffff_ffff
        }
        return self >= 32 ? 0x0000_0000 : (1 << (32 - self)) - 1
    }

    /// Compute a bit mask that passes the prefix bits, given the network prefix mask length.
    /// 
    /// For IPv4 addresses, this calculates the network portion mask.
    /// - Returns: A 32-bit mask where network bits are set to 1
    public var prefixMask32: UInt32 {
        ~self.suffixMask32
    }

    /// Compute a bit mask that passes the suffix bits, given the network prefix mask length.
    /// 
    /// For truncated IPv6 addresses (48-bit), this calculates the host portion mask.
    /// - Returns: A 64-bit mask where host bits are set to 1 (masked to 48 bits)
    public var suffixMask48: UInt64 {
        if self <= 0 {
            return 0x0000_ffff_ffff_ffff
        }
        return self >= 48 ? 0x0000_0000_0000_0000 : (1 << (48 - self)) - 1
    }

    /// Compute a bit mask that passes the prefix bits, given the network prefix mask length.
    /// 
    /// For truncated IPv6 addresses (48-bit), this calculates the network portion mask.
    /// - Returns: A 64-bit mask where network bits are set to 1 (masked to 48 bits)
    public var prefixMask48: UInt64 {
        ~self.suffixMask48 & 0x0000_ffff_ffff_ffff
    }
}
