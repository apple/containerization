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
/// kernel's `/proc/net/snmp` and `/proc/net/netstat`.
///
/// These counters are per network namespace, not per interface, and count
/// loopback traffic. Containers that share a network namespace (the default
/// in a VM, where all containers share the VM's) therefore see the same values. The kernel keeps no per-protocol byte counters, so bytes
/// are only available for IP as a whole (`IpExt: InOctets/OutOctets`).
public struct ProcNetSnmp: Sendable, Equatable {
    public struct Counters: Sendable, Equatable {
        public var receivedPackets: UInt64 = 0
        public var transmittedPackets: UInt64 = 0
        public var receivedBytes: UInt64 = 0
        public var transmittedBytes: UInt64 = 0
        /// Packets discarded for lack of resources or a destination. The kernel's
        /// causes differ per protocol; see the field mapping in `init(snmp:netstat:)`.
        public var receivedDrops: UInt64 = 0
        public var transmittedDrops: UInt64 = 0
        /// Malformed or failed packets. Causes differ per protocol, as for drops.
        public var receivedErrors: UInt64 = 0
        public var transmittedErrors: UInt64 = 0

        public init() {}
    }

    /// TCP segments (`Tcp: InSegs/OutSegs`). No byte counters.
    public var tcp = Counters()
    /// UDP datagrams (`Udp: InDatagrams/OutDatagrams`). No byte counters.
    public var udp = Counters()
    /// ICMP messages (`Icmp: InMsgs/OutMsgs`). No byte counters.
    public var icmp = Counters()
    /// All IP packets (`Ip: InReceives/OutRequests`) and octets (`IpExt: InOctets/OutOctets`).
    public var ip = Counters()

    public init() {}

    /// Parse the contents of `/proc/net/snmp` and, optionally, `/proc/net/netstat`.
    ///
    /// Both files alternate a header line (`Proto: name name ...`) with a value line
    /// (`Proto: 1 2 ...`). Fields are matched by name so new kernel columns don't break parsing.
    public init(snmp: String, netstat: String? = nil) {
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
        // protocol maps the counters that fit best; unavailable ones stay zero.
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
    }

    /// Read the counters for the network namespace of process `pid`, or of the
    /// calling thread when `pid` is `nil`.
    public static func read(pid: Int32? = nil) throws -> ProcNetSnmp {
        let base = pid.map { "/proc/\($0)/net" } ?? "/proc/thread-self/net"
        let snmp = try String(contentsOfFile: "\(base)/snmp", encoding: .utf8)
        let netstat = try? String(contentsOfFile: "\(base)/netstat", encoding: .utf8)
        return ProcNetSnmp(snmp: snmp, netstat: netstat)
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
