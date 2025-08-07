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
///
/// `IPv4Address` provides multiple ways to create and work with IPv4 addresses:
/// - From dotted-decimal strings (e.g., "192.168.1.1")
/// - From network byte arrays in big-endian order
/// - From 32-bit integer values
///
/// The struct supports common networking operations like subnet prefix calculation
/// and provides seamless integration with JSON encoding/decoding.
///
/// ## Example usage:
/// ```swift
/// // Create from different representations
/// let addr1 = try IPv4Address("192.168.1.1")
/// let addr2 = try IPv4Address(fromNetworkBytes: [192, 168, 1, 1])
/// let addr3 = IPv4Address(fromValue: 0xc0a80101)
///
/// // All three represent the same address
/// print(addr1 == addr2 && addr2 == addr3) // true
///
/// // Get network prefix
/// let network = addr1.prefix(prefixLength: 24) // 192.168.1.0
/// ```
public struct IPv4Address: Codable, CustomStringConvertible, Equatable, Sendable {
    /// The address as a 32-bit integer in host byte order.
    public let value: UInt32

    /// Create an address from a dotted-decimal string.
    /// 
    /// - Parameter fromString: An IPv4 address in dotted-decimal notation (e.g., "192.168.64.10")
    /// - Throws: `NetworkAddressError.invalidStringAddress` if the string format is invalid
    ///
    /// ## Example:
    /// ```swift
    /// let address = try IPv4Address("10.0.0.1")
    /// print(address.description) // "10.0.0.1"
    /// ```
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

    /// Create an address from an array of four bytes in network order (big-endian).
    /// 
    /// - Parameter fromNetworkBytes: An array of exactly 4 bytes representing the IPv4 address
    /// - Throws: `NetworkAddressError.invalidNetworkByteAddress` if the array doesn't contain exactly 4 bytes
    ///
    /// ## Example:
    /// ```swift
    /// let bytes: [UInt8] = [192, 168, 1, 100]
    /// let address = try IPv4Address(fromNetworkBytes: bytes)
    /// print(address.description) // "192.168.1.100"
    /// ```
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

    /// Create an address from a 32-bit integer value.
    /// 
    /// - Parameter fromValue: A 32-bit integer representing the IPv4 address in host byte order
    ///
    /// ## Example:
    /// ```swift
    /// let address = IPv4Address(fromValue: 0xc0a80164) // 192.168.1.100
    /// print(address.description) // "192.168.1.100"
    /// ```
    public init(fromValue: UInt32) {
        value = fromValue
    }

    /// Returns the address as an array of bytes in network byte order (big-endian).
    /// 
    /// - Returns: An array of 4 bytes representing the IPv4 address
    ///
    /// This is useful for network programming where you need to send the address
    /// over the network in the standard big-endian format.
    ///
    /// ## Example:
    /// ```swift
    /// let address = try IPv4Address("10.0.0.1")
    /// let bytes = address.networkBytes // [10, 0, 0, 1]
    /// ```
    public var networkBytes: [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    /// Returns the address as a dotted-decimal string.
    ///
    /// This property provides the standard human-readable representation of the IPv4 address.
    public var description: String {
        networkBytes.map(String.init).joined(separator: ".")
    }

    /// Create the network base address for a subnet containing this address.
    /// 
    /// - Parameter prefixLength: The subnet mask length (0-32 bits)
    /// - Returns: The base IPv4 address of the network containing this address
    ///
    /// This method applies the subnet mask to get the network portion of the address,
    /// setting all host bits to zero.
    ///
    /// ## Example:
    /// ```swift
    /// let address = try IPv4Address("192.168.1.150")
    /// let network = address.prefix(prefixLength: 24) 
    /// print(network.description) // "192.168.1.0"
    /// 
    /// let subnetwork = address.prefix(prefixLength: 28)
    /// print(subnetwork.description) // "192.168.1.144"
    /// ```
    public func prefix(prefixLength: PrefixLength) -> IPv4Address {
        IPv4Address(fromValue: value & prefixLength.prefixMask32)
    }
}

// MARK: - Codable Conformance
extension IPv4Address {
    /// Creates an IPv4Address from a JSON string representation.
    /// 
    /// - Parameter decoder: The decoder to read data from
    /// - Throws: `DecodingError` if the string is not a valid IPv4 address format
    ///
    /// The JSON representation uses the standard dotted-decimal string format.
    ///
    /// ## Example JSON:
    /// ```json
    /// "192.168.1.1"
    /// ```
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        try self.init(text)
    }

    /// Encodes the IPv4Address as a JSON string in dotted-decimal format.
    /// 
    /// - Parameter encoder: The encoder to write data to
    /// - Throws: `EncodingError` if encoding fails
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }
}
