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
import Logging

/// One nftables mutation in a batch, applied by ``NfTablesSession``.
internal enum NfTablesMessage {
    case addTable(family: UInt8, name: String)
    case addChain(family: UInt8, table: String, chain: String, options: ChainOptions)
    case addDnatRule(family: UInt8, table: String, chain: String, rule: DNATRule)

    /// The netfilter family for the message's `nfgenmsg`.
    var family: UInt8 {
        switch self {
        case .addTable(let family, _), .addChain(let family, _, _, _),
            .addDnatRule(let family, _, _, _):
            return family
        }
    }

    var type: UInt16 {
        let raw: UInt16
        switch self {
        case .addTable: raw = NfTablesMessageType.NFT_MSG_NEWTABLE
        case .addChain: raw = NfTablesMessageType.NFT_MSG_NEWCHAIN
        case .addDnatRule: raw = NfTablesMessageType.NFT_MSG_NEWRULE
        }
        return (NfNetlinkSubsystem.NFNL_SUBSYS_NFTABLES << 8) | raw
    }

    /// The netlink message flags, matching the native `nft` CLI.
    var flags: UInt16 {
        var flags = NetlinkFlags.NLM_F_REQUEST
        switch self {
        case .addTable:
            break
        case .addChain:
            flags |= NetlinkFlags.NLM_F_CREATE
        case .addDnatRule:
            flags |= NetlinkFlags.NLM_F_CREATE | NetlinkFlags.NLM_F_APPEND
        }
        return flags
    }

    static func totalSize(attributes: [NfTablesAttribute]) -> Int {
        NetlinkMessageHeader.size + NfNetlinkGenMessage.size + NfTablesAttribute.renderSize(attributes)
    }

    /// Writes this message into `buffer` at `offset`, returning the new offset.
    func writeMessage(
        seq: UInt32, pid: UInt32, prefix: String, attributes: [NfTablesAttribute], _ buffer: inout [UInt8], offset: Int
    ) throws -> Int {
        var offset = offset

        let header = NetlinkMessageHeader(
            len: UInt32(Self.totalSize(attributes: attributes)), type: type, flags: flags, seq: seq, pid: pid)
        offset = try header.appendBuffer(&buffer, offset: offset)

        let nfgen = NfNetlinkGenMessage(family: family)
        offset = try nfgen.appendBuffer(&buffer, offset: offset)

        offset = try NfTablesAttribute.renderInto(attributes, &buffer, offset: offset)
        return offset
    }

    func attributes(prefix: String) -> [NfTablesAttribute] {
        switch self {
        case .addTable(_, let name):
            return [
                .string(TableAttributeType.NAME, prefix + name),
                .bigEndian(TableAttributeType.FLAGS, UInt32(0)),
            ]
        case .addChain(_, let table, let chain, let options):
            return [
                .string(ChainAttributeType.TABLE, prefix + table),
                .string(ChainAttributeType.NAME, prefix + chain),
            ] + options.makeAttributes()
        case .addDnatRule(_, let table, let chain, let rule):
            return [
                .string(RuleAttributeType.TABLE, prefix + table),
                .string(RuleAttributeType.CHAIN, prefix + chain),
                .nested(
                    RuleAttributeType.EXPRESSIONS,
                    rule.makeExpressions()),
            ]
        }
    }
}
public struct ChainOptions {
    /// The nftables chain type (`NFTA_CHAIN_TYPE`), e.g. `"nat"`.
    public var type: String
    /// The netfilter hook number (e.g. `NF_INET_LOCAL_OUT`).
    public var hook: UInt8
    /// The hook priority (e.g. NAT_DST = -100).
    public var priority: Int32
    /// The verdict applied to packets matching no rule (`NetfilterVerdict`);
    /// `nil` omits `NFTA_CHAIN_POLICY`, which defaults to NF_ACCEPT.
    public var policy: UInt32?

    /// Creates base chain attributes.
    public init(
        type: String, hook: UInt8, priority: Int32,
        policy: UInt32? = nil
    ) {
        self.type = type
        self.hook = hook
        self.priority = priority
        self.policy = policy
    }

    internal func makeAttributes() -> [NfTablesAttribute] {
        var attrs: [NfTablesAttribute] = []
        if let policy {
            attrs.append(.bigEndian(ChainAttributeType.POLICY, policy))
        }
        attrs += [
            .string(ChainAttributeType.TYPE, type),
            .nested(
                ChainAttributeType.HOOK,
                [
                    .bigEndian(HookAttributeType.HOOKNUM, UInt32(hook)),
                    .bigEndian(HookAttributeType.PRIORITY, priority),
                ]),
        ]
        return attrs
    }
}

/// A single DNAT rule to add via ``NfTablesSession.addDnatToOutput``.
public struct DNATRule {
    /// The IPv4 destination address to match.
    public var matchDaddr: IPv4Address
    /// The destination port to match.
    public var matchDport: UInt16
    /// The L4 protocol to match.
    public var matchProto: UInt8
    /// The IPv4 address the DNAT rule rewrites destinations to.
    public var dnatAddr: IPv4Address
    /// The port the DNAT rule rewrites destinations to.
    public var dnatPort: UInt16

    /// Creates a DNAT rule.
    public init(
        matchDaddr: IPv4Address, matchDport: UInt16, matchProto: UInt8,
        dnatAddr: IPv4Address, dnatPort: UInt16
    ) {
        self.matchDaddr = matchDaddr
        self.matchDport = matchDport
        self.matchProto = matchProto
        self.dnatAddr = dnatAddr
        self.dnatPort = dnatPort
    }

    internal func makeExpressions() -> [NfTablesAttribute] {
        var expressions: [NfTablesAttribute] = [
            .listElement(
                name: "payload",
                body: [
                    .bigEndian(PayloadAttributeType.DREG, NfTablesRegister.NFT_REG_1),
                    .bigEndian(PayloadAttributeType.BASE, NfTablesPayloadBase.NFT_PAYLOAD_NETWORK_HEADER),
                    .bigEndian(PayloadAttributeType.OFFSET, UInt32(16)),
                    .bigEndian(PayloadAttributeType.LEN, UInt32(4)),
                ]),
            .listElement(
                name: "cmp",
                body: [
                    .bigEndian(CompareAttributeType.SREG, NfTablesRegister.NFT_REG_1),
                    .bigEndian(CompareAttributeType.OP, NfTablesCompareOp.NFT_CMP_EQ),
                    .data(CompareAttributeType.DATA, self.matchDaddr.bytes),
                ]),
            .listElement(
                name: "meta",
                body: [
                    .bigEndian(MetaAttributeType.KEY, NfTablesMetaKey.NFT_META_L4PROTO),
                    .bigEndian(MetaAttributeType.DREG, NfTablesRegister.NFT_REG_1),
                ]),
            .listElement(
                name: "cmp",
                body: [
                    .bigEndian(CompareAttributeType.SREG, NfTablesRegister.NFT_REG_1),
                    .bigEndian(CompareAttributeType.OP, NfTablesCompareOp.NFT_CMP_EQ),
                    .data(CompareAttributeType.DATA, [self.matchProto]),
                ]),
            .listElement(
                name: "payload",
                body: [
                    .bigEndian(PayloadAttributeType.DREG, NfTablesRegister.NFT_REG_1),
                    .bigEndian(PayloadAttributeType.BASE, NfTablesPayloadBase.NFT_PAYLOAD_TRANSPORT_HEADER),
                    .bigEndian(PayloadAttributeType.OFFSET, UInt32(2)),
                    .bigEndian(PayloadAttributeType.LEN, UInt32(2)),
                ]),
            .listElement(
                name: "cmp",
                body: [
                    .bigEndian(CompareAttributeType.SREG, NfTablesRegister.NFT_REG_1),
                    .bigEndian(CompareAttributeType.OP, NfTablesCompareOp.NFT_CMP_EQ),
                    .data(CompareAttributeType.DATA, self.matchDport),
                ]),
            .listElement(
                name: "immediate",
                body: [
                    .bigEndian(ImmediateAttributeType.DREG, NfTablesRegister.NFT_REG_1),
                    .data(ImmediateAttributeType.DATA, self.dnatAddr.bytes),
                ]),
            .listElement(
                name: "immediate",
                body: [
                    .bigEndian(ImmediateAttributeType.DREG, NfTablesRegister.NFT_REG_2),
                    .data(ImmediateAttributeType.DATA, self.dnatPort),
                ]),
            .listElement(
                name: "nat",
                body: [
                    .bigEndian(NatAttributeType.TYPE, NfTablesNatType.NFT_NAT_DNAT),
                    .bigEndian(NatAttributeType.FAMILY, UInt32(NetfilterFamily.NFPROTO_IPV4)),
                    .bigEndian(NatAttributeType.REG_ADDR_MIN, NfTablesRegister.NFT_REG_1),
                    .bigEndian(NatAttributeType.REG_PROTO_MIN, NfTablesRegister.NFT_REG_2),
                    .bigEndian(NatAttributeType.FLAGS, NetfilterNatRange.NF_NAT_RANGE_PROTO_SPECIFIED),
                ]),
        ]

        return expressions
    }
}

/// Facilitates nftables netfilter messages over a `NETLINK_NETFILTER`
/// netlink socket, encoded exactly as the native `nft` CLI emits them
/// (big-endian scalar payloads). Mutations apply atomically as one batch.
public struct NfTablesSession {
    private static let receiveBufferSize = 65536

    /// Sequence/batch entry: one `nlmsghdr` + `nfgenmsg`.
    private static let batchMessageSize = NetlinkMessageHeader.size + NfNetlinkGenMessage.size

    /// Prefix applied to every nftables object name.
    private static let nftNamePrefix = "containerization-"

    private let socket: any NetlinkSocket
    private let log: Logger

    /// Creates a new `NfTablesSession`.
    /// - Parameters:
    ///   - socket: The `NetlinkSocket`, opened on `NETLINK_NETFILTER`.
    ///   - log: The logger to use. Defaults to a netfilter-scoped logger.
    public init(socket: any NetlinkSocket, log: Logger? = nil) {
        self.socket = socket
        self.log = log ?? Logger(label: "com.apple.containerization.netfilter")
    }

    /// Errors that may occur during netlink interaction.
    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case unexpectedOffset(offset: Int, size: Int)

        /// The description of the errors.
        public var description: String {
            switch self {
            case .unexpectedOffset(let offset, let size):
                return "unexpected buffer state, offset = \(offset), size = \(size)"
            }
        }
    }

    /// Adds an nftables table. The `name` is namespaced at serialization with
    /// the session's `containerization-` prefix.
    public func addTable(family: UInt8, name: String) throws {
        try sendBatch([.addTable(family: family, name: name)])
    }

    /// Adds an nftables base chain. The `table` and `chain` names are
    /// namespaced at serialization with the session's `containerization-` prefix.
    public func addChain(family: UInt8, table: String, chain: String, options: ChainOptions) throws {
        try sendBatch([.addChain(family: family, table: table, chain: chain, options: options)])
    }

    /// Adds a DNAT output rule set: one atomic batch with the
    /// `containerization-nat` table + `containerization-output` base chain and
    /// one DNAT rule per entry. On any failure nothing is applied.
    public func addDnatToOutput(rules: [DNATRule]) throws {
        try sendBatch(try Self.buildDnatMessages(rules))
    }

    /// Sends one atomic batch and waits for its ack. On success the kernel
    /// replies with one zero `NLMSG_ERROR` for BATCH_END; on failure it queues
    /// one non-zero `NLMSG_ERROR` per failed message and applies nothing. The
    /// first error decides; the rest stay queued, so a fresh socket is used
    /// for each batch.
    func sendBatch(_ messages: [NfTablesMessage]) throws {
        let bytes = try Self.buildBatch(messages, pid: socket.pid)
        try sendRequest(bytes)
        try receiveResponse()
    }

    private func sendRequest(_ bytes: [UInt8]) throws {
        log.trace("SEND-LENGTH: \(bytes.count)")
        log.trace("SEND-DUMP: \(bytes.hexEncodedString())")
        let sent = try socket.send(buf: bytes.withUnsafeBytes { $0.baseAddress }, len: bytes.count, flags: 0)
        if sent != bytes.count {
            log.warning("sent length \(sent) not equal to packet length \(bytes.count)")
        }
    }

    private func receiveResponse() throws {
        var buffer = [UInt8](repeating: 0, count: Self.receiveBufferSize)
        let size = try socket.recv(buf: &buffer, len: Self.receiveBufferSize, flags: 0)
        log.trace("RECV-LENGTH: \(size)")
        log.trace("RECV-DUMP: \(buffer[0..<size].hexEncodedString())")

        // A single buffer may hold several netlink messages.
        var offset = 0
        while offset + NetlinkMessageHeader.size <= size {
            var header = NetlinkMessageHeader()
            _ = try header.bindBuffer(&buffer, offset: offset)
            if header.type == NetlinkType.NLMSG_ERROR {
                // Error code is a signed Int32 immediately after the header.
                guard let errorPtr = buffer.bind(as: Int32.self, offset: offset + NetlinkMessageHeader.size) else {
                    throw BindError.recvMarshalFailure(type: "NetlinkErrorMessage", field: "error")
                }
                let rc = errorPtr.pointee
                log.trace("RECV-ERR-CODE: \(rc)")
                guard rc == 0 else {
                    throw NetlinkDataError.responseError(rc: rc)
                }
                return
            }
            guard header.len > 0 else {
                break
            }
            offset += Int(header.len)
        }
    }

    static func buildDnatMessages(_ rules: [DNATRule]) throws -> [NfTablesMessage] {
        let table = "nat"
        let chain = "output"
        var messages: [NfTablesMessage] = [
            .addTable(family: NetfilterFamily.NFPROTO_IPV4, name: table),
            .addChain(
                family: NetfilterFamily.NFPROTO_IPV4,
                table: table,
                chain: chain,
                options: ChainOptions(
                    type: "nat",
                    hook: NetfilterHook.NF_INET_LOCAL_OUT,
                    priority: NetfilterHookPriority.NF_IP_PRI_NAT_DST)),
        ]
        messages += rules.map {
            .addDnatRule(
                family: NetfilterFamily.NFPROTO_IPV4,
                table: table,
                chain: chain,
                rule: $0)
        }
        return messages
    }

    static func buildBatch(_ messages: [NfTablesMessage], pid: UInt32) throws -> [UInt8] {
        let attributesByMessage = messages.map { $0.attributes(prefix: Self.nftNamePrefix) }
        var total = Self.batchMessageSize
        for attributes in attributesByMessage {
            total += NfTablesMessage.totalSize(attributes: attributes)
        }
        total += Self.batchMessageSize

        var buffer = [UInt8](repeating: 0, count: total)
        var offset = try Self.writeBatchMessage(type: NfNetlinkBatchMessage.NFNL_MSG_BATCH_BEGIN, seq: 0, pid: pid, &buffer, offset: 0)
        for (index, attributes) in attributesByMessage.enumerated() {
            offset = try messages[index].writeMessage(
                seq: UInt32(index + 1), pid: pid, prefix: Self.nftNamePrefix, attributes: attributes, &buffer, offset: offset)
        }
        // The batch's one ACK rides on END (messages carry none); see sendBatch.
        offset = try Self.writeBatchMessage(
            type: NfNetlinkBatchMessage.NFNL_MSG_BATCH_END, seq: UInt32(messages.count + 1), pid: pid,
            flags: NetlinkFlags.NLM_F_REQUEST | NetlinkFlags.NLM_F_ACK, &buffer, offset: offset)
        guard offset == total else {
            throw NfTablesSession.Error.unexpectedOffset(offset: offset, size: total)
        }
        return buffer
    }

    private static func writeBatchMessage(
        type: UInt16, seq: UInt32, pid: UInt32, flags: UInt16 = NetlinkFlags.NLM_F_REQUEST,
        _ buffer: inout [UInt8], offset: Int
    ) throws -> Int {
        var offset = offset

        let header = NetlinkMessageHeader(
            len: UInt32(Self.batchMessageSize), type: type, flags: flags, seq: seq, pid: pid)
        offset = try header.appendBuffer(&buffer, offset: offset)

        let nfgen = NfNetlinkGenMessage(
            family: NetfilterFamily.NFPROTO_UNSPEC, version: NfNetlinkVersion.NFNETLINK_V0, resID: NfNetlinkSubsystem.NFNL_SUBSYS_NFTABLES)
        offset = try nfgen.appendBuffer(&buffer, offset: offset)
        return offset
    }
}
