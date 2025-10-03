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

/// Errors related to IP and CIDR addresses.
public enum NetworkAddressError: Swift.Error, Equatable, CustomStringConvertible {
    case invalidStringAddress(address: String)
    case invalidNetworkByteAddress(address: [UInt8])
    case invalidCIDR(cidr: String)
    case invalidAddressForSubnet(address: String, cidr: String)
    case invalidAddressRange(lower: String, upper: String)

    public var description: String {
        switch self {
        case .invalidStringAddress(let address):
            return "invalid IP address string \(address)"
        case .invalidNetworkByteAddress(let address):
            return "invalid IP address bytes \(address)"
        case .invalidCIDR(let cidr):
            return "invalid CIDR block: \(cidr)"
        case .invalidAddressForSubnet(let address, let cidr):
            return "invalid address \(address) for subnet \(cidr)"
        case .invalidAddressRange(let lower, let upper):
            return "invalid range for addresses \(lower) and \(upper)"
        }
    }
}

public typealias PrefixLength = UInt8

extension PrefixLength {
    /// Compute a bit mask that passes the suffix bits, given the network prefix mask length.
    public var suffixMask32: UInt32 {
        if self <= 0 {
            return 0xffff_ffff
        }
        return self >= 32 ? 0x0000_0000 : (1 << (32 - self)) - 1
    }

    /// Compute a bit mask that passes the prefix bits, given the network prefix mask length.
    public var prefixMask32: UInt32 {
        ~self.suffixMask32
    }

    /// Compute a bit mask that passes the suffix bits, given the network prefix mask length.
    public var suffixMask48: UInt64 {
        if self <= 0 {
            return 0x0000_ffff_ffff_ffff
        }
        return self >= 48 ? 0x0000_0000_0000_0000 : (1 << (48 - self)) - 1
    }

    /// Compute a bit mask that passes the prefix bits, given the network prefix mask length.
    public var prefixMask48: UInt64 {
        ~self.suffixMask48 & 0x0000_ffff_ffff_ffff
    }
}
