//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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

/// A network interface's addresses.
public struct InterfaceAddress: Sendable, Hashable {
    public var ipv4Address: CIDRv4
    public var ipv6Address: CIDRv6?

    public init(ipv4Address: CIDRv4, ipv6Address: CIDRv6? = nil) {
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
    }
}

/// A link-scoped route — a destination directly reachable on an interface.
public struct LinkRoute: Sendable, Hashable {
    public var ipv4Destination: IPv4Address?
    public var ipv4Source: IPv4Address?
    public var ipv6Destination: IPv6Address?
    public var ipv6Source: IPv6Address?

    public init(
        ipv4Destination: IPv4Address? = nil,
        ipv4Source: IPv4Address? = nil,
        ipv6Destination: IPv6Address? = nil,
        ipv6Source: IPv6Address? = nil
    ) {
        self.ipv4Destination = ipv4Destination
        self.ipv4Source = ipv4Source
        self.ipv6Destination = ipv6Destination
        self.ipv6Source = ipv6Source
    }
}

/// The default-route gateway for a network interface.
public struct DefaultRoute: Sendable, Hashable {
    public var ipv4Gateway: IPv4Address?
    public var ipv6Gateway: IPv6Address?

    public init(ipv4Gateway: IPv4Address? = nil, ipv6Gateway: IPv6Address? = nil) {
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Gateway = ipv6Gateway
    }
}
