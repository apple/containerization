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

import ContainerizationExtras
import Testing

@testable import Containerization

struct InterfaceTests {

    /// A minimal `Interface` conformer that only sets the IPv4 surface, relying on the
    /// protocol's default extensions to fill in `ipv6Address`, `ipv6Gateway`, and `mtu`.
    private struct V4OnlyInterface: Interface {
        let ipv4Address: CIDRv4?
        let ipv4Gateway: IPv4Address?
        let macAddress: MACAddress?
    }

    @Test func interfaceProtocolV6Defaults() throws {
        let i = V4OnlyInterface(
            ipv4Address: try CIDRv4("10.0.0.2/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"),
            macAddress: nil)
        #expect(i.ipv6Address == nil)
        #expect(i.ipv6Gateway == nil)
        #expect(i.mtu == 1500)
    }

    @Test func natInterfaceRoundTripsV6Fields() throws {
        let nat = NATInterface(
            ipv4Address: try CIDRv4("10.0.0.2/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"),
            ipv6Address: try CIDRv6("fd00::2/64"),
            ipv6Gateway: try IPv6Address("fd00::1"))
        #expect(nat.ipv6Address == (try CIDRv6("fd00::2/64")))
        #expect(nat.ipv6Gateway == (try IPv6Address("fd00::1")))
    }

    @Test func natInterfaceV6FieldsDefaultToNil() throws {
        let nat = NATInterface(
            ipv4Address: try CIDRv4("10.0.0.2/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"))
        #expect(nat.ipv6Address == nil)
        #expect(nat.ipv6Gateway == nil)
    }
}
