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

/// Facilitates conversion between IPv4 address representations.
public struct IPv4Address: Codable, CustomStringConvertible, Equatable, Sendable {
    /// The address as a 32-bit integer.
    public let value: UInt32

    /// Create an address from a dotted-decimal string, such as "192.168.64.10".
    public init(_ fromString: String) throws {
        let split = fromString.components(separatedBy: ".")
        if split.count != 4 {
            throw NetworkAddressError.invalidStringAddress(address: fromString)
        }

        var parsedValue: UInt32 = 0
        for index in 0..<4 {
            guard let octet = UInt8(split[index]) else {
                throw NetworkAddressError.invalidStringAddress(address: fromString)
            }
            parsedValue |= UInt32(octet) << ((3 - index) * 8)
        }

        value = parsedValue
    }

    /// Create an address from an array of four bytes in network order (big-endian),
    /// such as [192, 168, 64, 10].
    public init(fromNetworkBytes: [UInt8]) throws {
        guard fromNetworkBytes.count == 4 else {
            throw NetworkAddressError.invalidNetworkByteAddress(address: fromNetworkBytes)
        }

        value =
            (UInt32(fromNetworkBytes[0]) << 24)
            | (UInt32(fromNetworkBytes[1]) << 16)
            | (UInt32(fromNetworkBytes[2]) << 8)
            | UInt32(fromNetworkBytes[3])
    }

    /// Create an address from a 32-bit integer, such as 0xc0a8_400a.
    public init(fromValue: UInt32) {
        value = fromValue
    }

    /// Retrieve the address as an array of bytes in network byte order.
    public var networkBytes: [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    /// Retrieve the address as a dotted decimal string.
    public var description: String {
        networkBytes.map(String.init).joined(separator: ".")
    }

    /// Create the base IPv4 address for a network that contains this
    /// address and uses the specified subnet mask length.
    public func prefix(prefixLength: PrefixLength) -> IPv4Address {
        IPv4Address(fromValue: value & prefixLength.prefixMask32)
    }
}

extension IPv4Address {
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
