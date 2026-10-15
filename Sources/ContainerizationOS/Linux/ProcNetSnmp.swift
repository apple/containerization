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

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Protocol-level traffic counters for a network namespace, parsed from the
/// kernel's `/proc/net/snmp`, `/proc/net/netstat` and `/proc/net/snmp6`.
///
/// These counters are per network namespace, not per interface, and count
/// loopback traffic. Containers that share a network namespace (the default
/// in a VM, where all containers share the VM's) therefore see the same values. The kernel keeps no per-protocol byte counters, so bytes
/// are only available for IP as a whole (`IpExt: InOctets/OutOctets` for IPv4, `Ip6InOctets/Ip6OutOctets` for IPv6).
public struct ProcNetSnmp: Sendable, Equatable {
    public struct Counters: Sendable, Equatable {
        public var receivedPackets: UInt64 = 0
        public var transmittedPackets: UInt64 = 0
        /// `nil` when the kernel keeps no such counter for the protocol.
        public var receivedBytes: UInt64?
        public var transmittedBytes: UInt64?
        /// Packets discarded for lack of resources or a destination. The kernel's
        /// causes differ per protocol; see the field mapping in `init(snmp:netstat:)`.
        /// `nil` when the protocol has no matching counter, as opposed to `0` for "none happened".
        public var receivedDrops: UInt64?
        public var transmittedDrops: UInt64?
        /// Malformed or failed packets. Causes differ per protocol, as for drops.
        public var receivedErrors: UInt64?
        public var transmittedErrors: UInt64?

        public init() {}
    }

    /// TCP segments (`Tcp: InSegs/OutSegs`). No byte counters. The kernel shares its TCP
    /// counters between IPv4 and IPv6, so these cover both families and there is no `tcp6`.
    public var tcp = Counters()
    /// IPv4 UDP datagrams (`Udp: InDatagrams/OutDatagrams`). No byte counters.
    public var udp = Counters()
    /// IPv4 ICMP messages (`Icmp: InMsgs/OutMsgs`). No byte counters.
    public var icmp = Counters()
    /// All IPv4 packets (`Ip: InReceives/OutRequests`) and octets (`IpExt: InOctets/OutOctets`).
    public var ip = Counters()
    /// IPv6 UDP datagrams (`Udp6InDatagrams/Udp6OutDatagrams`). `nil` when `/proc/net/snmp6` is unavailable.
    public var udp6: Counters?
    /// IPv6 ICMP messages (`Icmp6InMsgs/Icmp6OutMsgs`). `nil` when `/proc/net/snmp6` is unavailable.
    public var icmp6: Counters?
    /// All IPv6 packets (`Ip6InReceives/Ip6OutRequests`) and octets (`Ip6InOctets/Ip6OutOctets`).
    /// `nil` when `/proc/net/snmp6` is unavailable.
    public var ip6: Counters?

    public init() {}

    /// Parse the contents of `/proc/net/snmp` and, optionally, `/proc/net/netstat` and `/proc/net/snmp6`.
    ///
    /// `snmp` and `netstat` alternate a header line (`Proto: name name ...`) with a value line
    /// (`Proto: 1 2 ...`). `snmp6` has one `Name value` pair per line. Fields are matched by
    /// name so new kernel columns don't break parsing. IPv6 counters from `snmp6` are kept apart
    /// from the IPv4 ones in `udp6`, `icmp6` and `ip6`, and stay `nil` when `snmp6` is absent.
    public init(snmp: String, netstat: String? = nil, snmp6: String? = nil) {
        let snmpTables = Self.tables(snmp)
        let netstatTables = netstat.map(Self.tables) ?? [:]

        tcp.receivedPackets = snmpTables["Tcp"]?["InSegs"] ?? 0
        tcp.transmittedPackets = snmpTables["Tcp"]?["OutSegs"] ?? 0
        udp.receivedPackets = snmpTables["Udp"]?["InDatagrams"] ?? 0
        udp.transmittedPackets = snmpTables["Udp"]?["OutDatagrams"] ?? 0
        icmp.receivedPackets = snmpTables["Icmp"]?["InMsgs"] ?? 0
        icmp.transmittedPackets = snmpTables["Icmp"]?["OutMsgs"] ?? 0
        ip.receivedPackets = snmpTables["Ip"]?["InReceives"] ?? 0
        ip.transmittedPackets = snmpTables["Ip"]?["OutRequests"] ?? 0
        ip.receivedBytes = netstatTables["IpExt"]?["InOctets"] ?? 0
        ip.transmittedBytes = netstatTables["IpExt"]?["OutOctets"] ?? 0

        // Drops and errors. The kernel has no uniform notion of either, so each
        // protocol maps the counters that fit best; unsupported ones stay nil.
        func sum(_ table: [String: UInt64]?, _ names: String...) -> UInt64 {
            names.reduce(0) { $0 &+ (table?[$1] ?? 0) }
        }
        let tcpExt = netstatTables["TcpExt"]
        let udpTable = snmpTables["Udp"]
        let ipTable = snmpTables["Ip"]

        tcp.receivedDrops = sum(tcpExt, "ListenDrops", "TCPBacklogDrop", "TCPRcvQDrop")
        tcp.receivedErrors = snmpTables["Tcp"]?["InErrs"] ?? 0

        // Udp InErrors already includes RcvbufErrors, so subtract it to keep the two disjoint.
        udp.receivedDrops = sum(udpTable, "RcvbufErrors", "NoPorts")
        udp.receivedErrors = (udpTable?["InErrors"] ?? 0).subtractingClamped(udpTable?["RcvbufErrors"] ?? 0)
        udp.transmittedDrops = udpTable?["SndbufErrors"] ?? 0

        icmp.receivedErrors = snmpTables["Icmp"]?["InErrors"] ?? 0
        icmp.transmittedErrors = snmpTables["Icmp"]?["OutErrors"] ?? 0

        // InNoRoutes lives in IpExt (netstat), not Ip (snmp).
        ip.receivedDrops = sum(ipTable, "InDiscards") &+ sum(netstatTables["IpExt"], "InNoRoutes")
        ip.receivedErrors = sum(ipTable, "InHdrErrors", "InAddrErrors", "InUnknownProtos")
        ip.transmittedDrops = sum(ipTable, "OutDiscards", "OutNoRoutes")
        ip.transmittedErrors = ipTable?["FragFails"] ?? 0

        guard let snmp6 else { return }

        // The same mapping as IPv4, but every IPv6 counter is in snmp6, including octets and InNoRoutes.
        let udp6Table = Self.snmp6Fields(snmp6, prefix: "Udp6")
        var udp6 = Counters()
        udp6.receivedPackets = udp6Table["InDatagrams"] ?? 0
        udp6.transmittedPackets = udp6Table["OutDatagrams"] ?? 0
        udp6.receivedDrops = sum(udp6Table, "RcvbufErrors", "NoPorts")
        udp6.receivedErrors = (udp6Table["InErrors"] ?? 0).subtractingClamped(udp6Table["RcvbufErrors"] ?? 0)
        udp6.transmittedDrops = udp6Table["SndbufErrors"] ?? 0
        self.udp6 = udp6

        let icmp6Table = Self.snmp6Fields(snmp6, prefix: "Icmp6")
        var icmp6 = Counters()
        icmp6.receivedPackets = icmp6Table["InMsgs"] ?? 0
        icmp6.transmittedPackets = icmp6Table["OutMsgs"] ?? 0
        icmp6.receivedErrors = icmp6Table["InErrors"] ?? 0
        icmp6.transmittedErrors = icmp6Table["OutErrors"] ?? 0
        self.icmp6 = icmp6

        let ip6Table = Self.snmp6Fields(snmp6, prefix: "Ip6")
        var ip6 = Counters()
        ip6.receivedPackets = ip6Table["InReceives"] ?? 0
        ip6.transmittedPackets = ip6Table["OutRequests"] ?? 0
        ip6.receivedBytes = ip6Table["InOctets"] ?? 0
        ip6.transmittedBytes = ip6Table["OutOctets"] ?? 0
        ip6.receivedDrops = sum(ip6Table, "InDiscards", "InNoRoutes")
        ip6.receivedErrors = sum(ip6Table, "InHdrErrors", "InAddrErrors", "InUnknownProtos")
        ip6.transmittedDrops = sum(ip6Table, "OutDiscards", "OutNoRoutes")
        ip6.transmittedErrors = ip6Table["FragFails"] ?? 0
        self.ip6 = ip6
    }

    /// Read the counters for the network namespace of process `pid`, or of the
    /// calling thread when `pid` is `nil`.
    public static func read(pid: Int32? = nil) throws -> ProcNetSnmp {
        let base = pid.map { "/proc/\($0)/net" } ?? "/proc/thread-self/net"
        let snmp = try String(contentsOfFile: "\(base)/snmp", encoding: .utf8)
        let netstat = try? String(contentsOfFile: "\(base)/netstat", encoding: .utf8)
        // Absent when IPv6 is disabled in the guest kernel.
        let snmp6 = try? String(contentsOfFile: "\(base)/snmp6", encoding: .utf8)
        return ProcNetSnmp(snmp: snmp, netstat: netstat, snmp6: snmp6)
    }

    /// Returns the `/proc/net/snmp6` fields starting with `prefix`, keyed by the name after it.
    ///
    /// Unlike `snmp` and `netstat`, each line holds one `Name value` pair, separated by spaces or tabs.
    /// Given
    /// ```
    /// Ip6InReceives                   	50
    /// Ip6InOctets                     	1000
    /// Udp6InDatagrams                 	60
    /// Udp6NoPorts                     	5
    /// Icmp6InMsgs                     	6
    /// ```
    /// and prefix `Udp6`, this returns `["InDatagrams": 60, "NoPorts": 5]`. Lines for other
    /// prefixes are skipped, as are values that don't parse as unsigned.
    private static func snmp6Fields(_ contents: String?, prefix: String) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        guard let contents else { return result }
        for line in contents.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, parts[0].hasPrefix(prefix), let value = UInt64(parts[1]) else { continue }
            result[String(parts[0].dropFirst(prefix.count))] = value
        }
        return result
    }

    /// Returns `[protocol: [field: value]]` from alternating header/value lines.
    ///
    /// Given
    /// ```
    /// Udp: InDatagrams NoPorts InErrors
    /// Udp: 300 1 0
    /// Tcp: RtoAlgorithm MaxConn InSegs
    /// Tcp: 1 -1 600
    /// ```
    /// this returns `["Udp": ["InDatagrams": 300, "NoPorts": 1, "InErrors": 0], "Tcp": ["RtoAlgorithm": 1, "InSegs": 600]]`.
    /// `MaxConn` is left out because `-1` doesn't parse as unsigned.
    private static func tables(_ contents: String) -> [String: [String: UInt64]] {
        var result: [String: [String: UInt64]] = [:]
        var header: (proto: String, names: [Substring])?
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first, first.hasSuffix(":") else {
                header = nil
                continue
            }
            let proto = String(first.dropLast())
            let fields = Array(parts.dropFirst())
            guard let h = header, h.proto == proto, h.names.count == fields.count else {
                // A header line (or a mismatched pair); the next line should hold its values.
                header = (proto, fields)
                continue
            }
            var table: [String: UInt64] = [:]
            for (name, value) in zip(h.names, fields) {
                // Some fields (e.g. `Tcp: MaxConn`) are signed; negative means "unset".
                if let v = UInt64(value) { table[String(name)] = v }
            }
            result[proto] = table
            header = nil
        }
        return result
    }
}

extension UInt64 {
    fileprivate func subtractingClamped(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}
