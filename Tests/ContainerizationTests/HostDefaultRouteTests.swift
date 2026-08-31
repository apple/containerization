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

import Testing

@testable import Containerization

@Suite("Host default route parsing")
struct HostDefaultRouteTests {
    // Header + one default-route row (Destination=00000000, Flags=0003 has RTF_GATEWAY=0x2).
    static let singleDefault = """
        Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT
        eth0\t00000000\t0102A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0
        eth0\t0002A8C0\t00000000\t0001\t0\t0\t0\tFFFFFF00\t0\t0\t0
        """

    static let noDefault = """
        Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT
        eth0\t0002A8C0\t00000000\t0001\t0\t0\t0\tFFFFFF00\t0\t0\t0
        """

    static let multiDefault = """
        Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT
        wlan0\t00000000\t0102A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0
        eth0\t00000000\t0102A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0
        """

    @Test("returns iface for a single default route")
    func singleDefaultRoute() {
        #expect(HostDefaultRoute.parseEgress(procNetRoute: Self.singleDefault) == "eth0")
    }

    @Test("returns nil when no default route")
    func noDefaultRoute() {
        #expect(HostDefaultRoute.parseEgress(procNetRoute: Self.noDefault) == nil)
    }

    @Test("returns lowest-metric default when multiple")
    func multipleDefaultRoutes() {
        // eth0 has metric 100; wlan0 has metric 600.
        #expect(HostDefaultRoute.parseEgress(procNetRoute: Self.multiDefault) == "eth0")
    }

    @Test("ignores rows missing RTF_GATEWAY flag")
    func noGatewayFlag() {
        // Same as singleDefault but flags=0001 (no RTF_GATEWAY=0x2).
        let input = """
            Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT
            eth0\t00000000\t0102A8C0\t0001\t0\t0\t0\t00000000\t0\t0\t0
            """
        #expect(HostDefaultRoute.parseEgress(procNetRoute: input) == nil)
    }
}
