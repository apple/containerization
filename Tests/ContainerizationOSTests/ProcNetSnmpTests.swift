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

    static let errorsSnmp = """
        Ip: InHdrErrors InAddrErrors InUnknownProtos InDiscards OutDiscards OutNoRoutes FragFails
        Ip: 1 2 3 4 5 6 7
        Icmp: InErrors OutErrors
        Icmp: 8 9
        Tcp: InErrs
        Tcp: 10
        Udp: NoPorts InErrors RcvbufErrors SndbufErrors
        Udp: 11 20 12 13
        """

    static let errorsNetstat = """
        TcpExt: ListenDrops TCPBacklogDrop TCPRcvQDrop
        TcpExt: 14 15 16
        IpExt: InNoRoutes
        IpExt: 17
        """

    @Test func parsesDropsAndErrors() {
        let s = ProcNetSnmp(snmp: Self.errorsSnmp, netstat: Self.errorsNetstat)
        #expect(s.tcp.receivedDrops == 14 + 15 + 16)
        #expect(s.tcp.receivedErrors == 10)
        #expect(s.tcp.transmittedDrops == nil)
        #expect(s.tcp.transmittedErrors == nil)
        // RcvbufErrors + NoPorts; InErrors minus the RcvbufErrors it already includes.
        #expect(s.udp.receivedDrops == 12 + 11)
        #expect(s.udp.receivedErrors == 20 - 12)
        #expect(s.udp.transmittedDrops == 13)
        #expect(s.icmp.receivedErrors == 8)
        #expect(s.icmp.transmittedErrors == 9)
        #expect(s.icmp.receivedDrops == nil)
        #expect(s.icmp.transmittedDrops == nil)
        #expect(s.udp.transmittedErrors == nil)
        #expect(s.ip.receivedDrops == 4 + 17)
        #expect(s.ip.receivedErrors == 1 + 2 + 3)
        #expect(s.ip.transmittedDrops == 5 + 6)
        #expect(s.ip.transmittedErrors == 7)
    }

    @Test func udpErrorsClampWhenRcvbufExceedsInErrors() {
        let s = ProcNetSnmp(snmp: "Udp: InErrors RcvbufErrors\nUdp: 3 5\n")
        #expect(s.udp.receivedErrors == 0)
        #expect(s.udp.receivedDrops == 5)
    }

    @Test func missingNetstatLeavesIPBytesZero() {
        let s = ProcNetSnmp(snmp: Self.snmp)
        #expect(s.ip.receivedPackets == 1000)
        #expect(s.ip.receivedBytes == 0)
    }

    static let snmp6 = """
        Ip6InReceives                   \t50
        Ip6InHdrErrors                  \t1
        Ip6InNoRoutes                   \t2
        Ip6InDiscards                   \t3
        Ip6OutRequests                  \t40
        Ip6OutDiscards                  \t4
        Ip6InOctets                     \t1000
        Ip6OutOctets                    \t2000
        Icmp6InMsgs                     \t6
        Icmp6InErrors                   \t1
        Icmp6OutMsgs                    \t7
        Udp6InDatagrams                 \t60
        Udp6NoPorts                     \t5
        Udp6InErrors                    \t9
        Udp6OutDatagrams                \t70
        Udp6RcvbufErrors                \t4
        """

    @Test func keepsIPv6CountersSeparateFromIPv4() {
        // Parsing the same snmp and netstat with and without snmp6 gives identical IPv4 counters,
        // so no IPv6 value is added into ip, udp or icmp. snmp6 has no Tcp6 group, so tcp is unaffected too.
        let s = ProcNetSnmp(snmp: Self.snmp, netstat: Self.netstat, snmp6: Self.snmp6)

        #expect(s.ip == ProcNetSnmp(snmp: Self.snmp, netstat: Self.netstat).ip)
        #expect(s.udp == ProcNetSnmp(snmp: Self.snmp, netstat: Self.netstat).udp)
        #expect(s.icmp == ProcNetSnmp(snmp: Self.snmp, netstat: Self.netstat).icmp)
        #expect(s.tcp.receivedPackets == 600)

        #expect(s.ip6?.receivedPackets == 50)
        #expect(s.ip6?.transmittedPackets == 40)
        #expect(s.ip6?.receivedBytes == 1000)
        #expect(s.ip6?.transmittedBytes == 2000)
        #expect(s.ip6?.receivedDrops == 3 + 2)
        #expect(s.ip6?.receivedErrors == 1)
        #expect(s.ip6?.transmittedDrops == 4)
        #expect(s.ip6?.transmittedErrors == 0)
        #expect(s.udp6?.receivedPackets == 60)
        #expect(s.udp6?.transmittedPackets == 70)
        // NoPorts plus RcvbufErrors; InErrors minus the RcvbufErrors it already includes.
        #expect(s.udp6?.receivedDrops == 5 + 4)
        #expect(s.udp6?.receivedErrors == 9 - 4)
        #expect(s.icmp6?.receivedPackets == 6)
        #expect(s.icmp6?.transmittedPackets == 7)
        #expect(s.icmp6?.receivedErrors == 1)
        // Same unsupported counters as IPv4.
        #expect(s.udp6?.receivedBytes == nil)
        #expect(s.icmp6?.receivedDrops == nil)
        #expect(s.udp6?.transmittedErrors == nil)
    }

    @Test func missingSnmp6LeavesIPv6Nil() {
        let s = ProcNetSnmp(snmp: Self.snmp, netstat: Self.netstat)
        #expect(s.ip6 == nil)
        #expect(s.udp6 == nil)
        #expect(s.icmp6 == nil)
    }

    @Test func unsupportedCountersAreNil() {
        let s = ProcNetSnmp(snmp: Self.snmp, netstat: Self.netstat)
        #expect(s.tcp.receivedBytes == nil)
        #expect(s.tcp.transmittedBytes == nil)
        #expect(s.udp.receivedBytes == nil)
        #expect(s.udp.transmittedBytes == nil)
        #expect(s.icmp.receivedBytes == nil)
        #expect(s.icmp.transmittedBytes == nil)
        #expect(s.ip.receivedBytes != nil)
    }

    @Test func emptyAndMalformedInputYieldZeros() {
        for s in [ProcNetSnmp(snmp: ""), ProcNetSnmp(snmp: "Tcp: InSegs OutSegs\nTcp: 1\n")] {
            #expect(s.tcp.receivedPackets == 0)
            #expect(s.ip.receivedPackets == 0)
            // Supported counters read as zero, unsupported ones stay nil.
            #expect(s.tcp.receivedDrops == 0)
            #expect(s.tcp.transmittedDrops == nil)
            #expect(s.ip.receivedBytes == 0)
            #expect(s.udp.receivedBytes == nil)
        }
    }
}
