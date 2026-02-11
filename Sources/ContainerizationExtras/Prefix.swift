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

/// CIDR prefix length (e.g., `/24` for a 24-bit network mask).
@frozen
public struct Prefix: Sendable, CustomStringConvertible, Hashable, Codable {
    public let length: UInt8

    /// Create a prefix (0-128). Use `ipv4(_:)` or `ipv6(_:)` for version-specific validation.
    public init?(length: UInt8) {
        guard length <= 128 else { return nil }
        self.length = length
    }

    /// Create an IPv4 prefix (0-32). Returns `nil` if length > 32.
    public static func ipv4(_ length: UInt8) -> Prefix? {
        guard length <= 32 else { return nil }
        return Prefix(unchecked: length)
    }

    /// Create an IPv6 prefix (0-128). Returns `nil` if length > 128.
    public static func ipv6(_ length: UInt8) -> Prefix? {
        guard length <= 128 else { return nil }
        return Prefix(unchecked: length)
    }

    /// Internal unchecked initializer for known-valid values.
    internal init(unchecked length: UInt8) {
        self.length = length
    }

    public var description: String {
        "\(length)"
    }
}

extension Prefix {
    /// Computes a 32-bit mask for the suffix (host) portion of an IPv4 address.
    ///
    /// Example: Prefix `/24` → `0x0000_00FF` (255 host addresses)
    @inlinable
    public var suffixMask32: UInt32 {
        if self.length <= 0 {
            return 0xffff_ffff
        }
        return self.length >= 32 ? 0x0000_0000 : (1 << (32 - self.length)) - 1
    }

    /// Network portion mask (high-order bits) for IPv4.
    ///
    /// Example: Prefix `/24` → `0xFFFF_FF00` (255.255.255.0)
    @inlinable
    public var prefixMask32: UInt32 {
        ~self.suffixMask32
    }

    /// Computes a 128-bit mask for the suffix (host) portion of an IPv6 address.
    ///
    /// Example: Prefix `/64` → `0x0000_0000_0000_0000_FFFF_FFFF_FFFF_FFFF`
    @inlinable
    public var suffixMask128: UInt128 {
        if self.length <= 0 {
            return UInt128.max
        }
        return self.length >= 128 ? 0 : (1 << (128 - self.length)) - 1
    }

    /// Network portion mask (high-order bits) for IPv6.
    ///
    /// Example: Prefix `/64` → `0xFFFF_FFFF_FFFF_FFFF_0000_0000_0000_0000`
    @inlinable
    public var prefixMask128: UInt128 {
        ~self.suffixMask128
    }
}
