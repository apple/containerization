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

/// Represents an IP address that can be either IPv4 or IPv6.
@frozen
public enum IPAddress: Sendable, Hashable, CustomStringConvertible, Equatable {
    /// An IPv4 address
    case v4(IPv4Address)

    /// An IPv6 address
    case v6(IPv6Address)

    /// Parses an IP address string, automatically detecting IPv4 or IPv6 format.
    ///
    /// - Parameter string: IP address string to parse
    /// - Returns: An `IPAddress` containing either an IPv4 or IPv6 address
    /// - Throws: `AddressError.unableToParse` if invalid
    public init(_ string: String) throws {
        let utf8 = string.utf8
        var hasColon = false
        var hasDot = false

        for byte in utf8 {
            if byte == 58 {  // ASCII ':'
                hasColon = true
                break
            }
            if byte == 46 {  // ASCII '.'
                hasDot = true
            }
        }

        if hasColon {
            let ipv6 = try IPv6Address.parse(string)
            self = .v6(ipv6)
        } else if hasDot {
            let ipv4 = try IPv4Address(string)
            self = .v4(ipv4)
        } else {
            throw AddressError.unableToParse
        }
    }

    /// String representation of the IP address.
    public var description: String {
        switch self {
        case .v4(let addr):
            return addr.description
        case .v6(let addr):
            return addr.description
        }
    }

    /// Returns `true` if this is an IPv4 address.
    @inlinable
    public var isV4: Bool {
        if case .v4 = self {
            return true
        }
        return false
    }

    /// Returns `true` if this is an IPv6 address.
    @inlinable
    public var isV6: Bool {
        if case .v6 = self {
            return true
        }
        return false
    }

    /// Returns the underlying IPv4 address if this is an IPv4 address, otherwise `nil`.
    @inlinable
    public var ipv4: IPv4Address? {
        if case .v4(let addr) = self {
            return addr
        }
        return nil
    }

    /// Returns the underlying IPv6 address if this is an IPv6 address, otherwise `nil`.
    @inlinable
    public var ipv6: IPv6Address? {
        if case .v6(let addr) = self {
            return addr
        }
        return nil
    }

    /// Returns `true` if this is a loopback address (127.0.0.0/8 or ::1).
    @inlinable
    public var isLoopback: Bool {
        switch self {
        case .v4(let addr):
            return addr.isLoopback
        case .v6(let addr):
            return addr.isLoopback
        }
    }

    /// Returns `true` if this is a multicast address.
    @inlinable
    public var isMulticast: Bool {
        switch self {
        case .v4(let addr):
            return addr.isMulticast
        case .v6(let addr):
            return addr.isMulticast
        }
    }

    /// Returns `true` if this is an unspecified address (0.0.0.0 or ::).
    @inlinable
    public var isUnspecified: Bool {
        switch self {
        case .v4(let addr):
            return addr.isUnspecified
        case .v6(let addr):
            return addr.isUnspecified
        }
    }
}

extension IPAddress: Codable {
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
