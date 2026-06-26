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

#if os(Linux)
import CloudHypervisor
import ContainerizationExtras
import Testing

@testable import Containerization

@Suite("TAPInterface")
struct CHInterfaceTests {
    @Test("chNetConfig populates tap, mac, and mtu and leaves IP fields nil")
    func chNetConfigShape() throws {
        let cidr = try CIDRv4("192.168.64.3/24")
        let gateway = try IPv4Address("192.168.64.1")
        let mac = try MACAddress("02:42:ac:11:00:02")
        let iface = TAPInterface(
            tapName: "tap0",
            ipv4Address: cidr,
            ipv4Gateway: gateway,
            macAddress: mac,
            mtu: 1500
        )

        let cfg = try iface.chNetConfig()
        #expect(cfg.tap == "tap0")
        #expect(cfg.mac == mac.description)
        #expect(cfg.mtu == 1500)
        #expect(cfg.ip == nil)
        #expect(cfg.mask == nil)
        #expect(cfg.id == nil)
    }

    @Test("chNetConfig omits mac when macAddress is nil")
    func chNetConfigOmitsMac() throws {
        let cidr = try CIDRv4("10.0.0.5/24")
        let iface = TAPInterface(tapName: "ch-tap1", ipv4Address: cidr)

        let cfg = try iface.chNetConfig()
        #expect(cfg.tap == "ch-tap1")
        #expect(cfg.mac == nil)
        #expect(cfg.mtu == 1500)
    }

    @Test("TAPInterface satisfies Interface")
    func interfaceConformance() throws {
        let cidr = try CIDRv4("192.168.64.3/24")
        let iface: any Interface = TAPInterface(tapName: "tap0", ipv4Address: cidr)
        #expect(iface.ipv4Address == cidr)
        #expect(iface.ipv4Gateway == nil)
        #expect(iface.macAddress == nil)
        #expect(iface.mtu == 1500)
    }
}
#endif
