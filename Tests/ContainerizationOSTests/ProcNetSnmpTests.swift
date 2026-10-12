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

@testable import ContainerizationOS

@Suite("ProcNetSnmp tests")
struct ProcNetSnmpTests {
    static let snmp = """
        Ip: Forwarding DefaultTTL InReceives InHdrErrors OutRequests
        Ip: 2 64 1000 0 900
        Icmp: InMsgs InErrors OutMsgs
        Icmp: 7 0 5
        Tcp: RtoAlgorithm MaxConn InSegs OutSegs
        Tcp: 1 -1 600 500
        Udp: InDatagrams NoPorts OutDatagrams
        Udp: 300 1 250
        """

    static let netstat = """
        TcpExt: SyncookiesSent
        TcpExt: 0
        IpExt: InNoRoutes InOctets OutOctets
        IpExt: 0 123456 654321
        """

    @Test func parsesSnmpAndNetstat() {
        let s = ProcNetSnmp(snmp: Self.snmp, netstat: Self.netstat)
        #expect(s.tcp.receivedPackets == 600)
        #expect(s.tcp.transmittedPackets == 500)
        #expect(s.udp.receivedPackets == 300)
        #expect(s.udp.transmittedPackets == 250)
        #expect(s.icmp.receivedPackets == 7)
        #expect(s.icmp.transmittedPackets == 5)
        #expect(s.ip.receivedPackets == 1000)
        #expect(s.ip.transmittedPackets == 900)
        #expect(s.ip.receivedBytes == 123456)
        #expect(s.ip.transmittedBytes == 654321)
    }

    @Test func missingNetstatLeavesIPBytesZero() {
        let s = ProcNetSnmp(snmp: Self.snmp)
        #expect(s.ip.receivedPackets == 1000)
        #expect(s.ip.receivedBytes == 0)
    }

    @Test func emptyAndMalformedInputYieldZeros() {
        #expect(ProcNetSnmp(snmp: "") == ProcNetSnmp())
        #expect(ProcNetSnmp(snmp: "Tcp: InSegs OutSegs\nTcp: 1\n") == ProcNetSnmp())
    }
}
