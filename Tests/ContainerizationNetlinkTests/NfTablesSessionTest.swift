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

@testable import ContainerizationNetlink

struct NfTablesSessionTest {
    /// Ground-truth bytes of the native `nft` CLI's combined batch for the
    /// default redirect ruleset, byte-identical except the `NLM_F_ACK` on
    /// BATCH_END (the sole deviation from the capture); the end-to-end gate
    /// for layout, endianness, seq, flags.
    private let referenceFullBatchEndAckHex =
        // BATCH_BEGIN nlh (20 B): len=20 type=0x10 flags=REQUEST seq=0; nfgen res_id=0x000a (NFTABLES)
        "140000001000010000000000000000000000000a"
        // NEWTABLE nlmsghdr (16 B): len=56 type=0x0a00 flags=REQUEST seq=1; nfgen family=NFPROTO_IPV4 (2) — add table "containerization-nat"
        + "38000000000a010001000000000000000200000019000100636f6e7461696e6572697a6174696f6e2d6e6174000000000800020000000000"
        // NEWCHAIN nlmsghdr (16 B): len=104 type=0x0a03 flags=REQUEST|CREATE seq=2; nfgen family=NFPROTO_IPV4 (2) — add base chain "containerization-output"
        + "68000000030a010402000000000000000200000019000100636f6e7461696e6572697a6174696f6e2d6e6174000000001c000300636f6e7461696e6572697a6174696f6e2d6f757470757400080007006e61740014000480080001000000000308000200ffffff9c"
        // NEWRULE nlmsghdr (16 B): len=496 type=0x0a06 flags=REQUEST|CREATE|APPEND seq=3; nfgen family=NFPROTO_IPV4 (2) — add rule: UDP 192.0.2.2:53 → 198.51.100.100:3053
        + "f0010000060a010c03000000000000000200000019000100636f6e7461696e6572697a6174696f6e2d6e6174000000001c000200636f6e7461696e6572697a6174696f6e2d6f757470757400a4010480340001800c0001007061796c6f6164002400028008000100000000010800020000000001080003000000001008000400000000042c00018008000100636d700020000280080001000000000108000200000000000c00038008000100c000020224000180090001006d6574610000000014000280080002000000001008000100000000012c00018008000100636d700020000280080001000000000108000200000000000c0003800500010011000000340001800c0001007061796c6f6164002400028008000100000000010800020000000002080003000000000208000400000000022c00018008000100636d700020000280080001000000000108000200000000000c00038006000100003500002c0001800e000100696d6d6564696174650000001800028008000100000000010c00028008000100c63364642c0001800e000100696d6d6564696174650000001800028008000100000000020c000280060001000bed000038000180080001006e6174002c00028008000100000000010800020000000002080003000000000108000500000000020800070000000002"
        // NEWRULE nlmsghdr (16 B): len=496 type=0x0a06 flags=REQUEST|CREATE|APPEND seq=4; nfgen family=NFPROTO_IPV4 (2) — add rule: TCP 192.0.2.2:53 → 198.51.100.100:3053
        + "f0010000060a010c04000000000000000200000019000100636f6e7461696e6572697a6174696f6e2d6e6174000000001c000200636f6e7461696e6572697a6174696f6e2d6f757470757400a4010480340001800c0001007061796c6f6164002400028008000100000000010800020000000001080003000000001008000400000000042c00018008000100636d700020000280080001000000000108000200000000000c00038008000100c000020224000180090001006d6574610000000014000280080002000000001008000100000000012c00018008000100636d700020000280080001000000000108000200000000000c0003800500010006000000340001800c0001007061796c6f6164002400028008000100000000010800020000000002080003000000000208000400000000022c00018008000100636d700020000280080001000000000108000200000000000c00038006000100003500002c0001800e000100696d6d6564696174650000001800028008000100000000010c00028008000100c63364642c0001800e000100696d6d6564696174650000001800028008000100000000020c000280060001000bed000038000180080001006e6174002c00028008000100000000010800020000000002080003000000000108000500000000020800070000000002"
        // BATCH_END nlh (20 B): len=20 type=0x11 flags=REQUEST|ACK seq=5; nfgen res_id=0x000a (NFTABLES)
        + "140000001100050005000000000000000000000a"

    private var mockSocket: MockNetlinkSocket!

    /// The combined batch must byte-for-byte match the ground-truth bytes
    /// (two rules, UDP + TCP, no counter, with the NLM_F_ACK deviation and
    /// without the table userdata attr).
    @Test func buildBatchMatchesEndAckReference() throws {
        let rules = [
            DNATRule(
                matchDaddr: try IPv4Address("192.0.2.2"), matchDport: 53, matchProto: 17,
                dnatAddr: try IPv4Address("198.51.100.100"), dnatPort: 3053),
            DNATRule(
                matchDaddr: try IPv4Address("192.0.2.2"), matchDport: 53, matchProto: 6,
                dnatAddr: try IPv4Address("198.51.100.100"), dnatPort: 3053),
        ]

        let bytes = try NfTablesSession.buildBatch(try NfTablesSession.buildDnatMessages(rules), pid: 0)

        #expect(bytes.count == 1192)
        #expect(bytes == [UInt8](hex: referenceFullBatchEndAckHex))
    }

    /// `NfTablesAttribute` serialization matches the ground-truth bytes: the
    /// table attrs (`NAME` "nat" + `FLAGS` BE32 0) and the chain hook nest.
    @Test func renderNfTablesAttributeMatchesReference() throws {
        let tableAttrs: [NfTablesAttribute] = [
            .string(TableAttributeType.NAME, "nat"),
            .bigEndian(TableAttributeType.FLAGS, UInt32(0)),
        ]
        var tableBuffer = [UInt8](repeating: 0, count: NfTablesAttribute.renderSize(tableAttrs))
        _ = try NfTablesAttribute.renderInto(tableAttrs, &tableBuffer, offset: 0)
        #expect(
            tableBuffer
                == [UInt8](
                    hex:
                        "080001006e617400"  // attr hdr (len=8 type=NFTA_TABLE_NAME) + "nat\0"
                        + "0800020000000000"  // attr hdr (len=8 type=NFTA_TABLE_FLAGS) + BE32 0
                )
        )

        // The hook nest: len=20, type=HOOK|NLA_F_NESTED; children rendered
        // inside (HOOKNUM BE32 3, PRIORITY BE32 -100).
        let hookAttrs: [NfTablesAttribute] = [
            .nested(
                ChainAttributeType.HOOK,
                [
                    .bigEndian(HookAttributeType.HOOKNUM, UInt32(3)),
                    NfTablesAttribute.bigEndian(HookAttributeType.PRIORITY, Int32(-100)),
                ])
        ]
        var hookBuffer = [UInt8](repeating: 0, count: NfTablesAttribute.renderSize(hookAttrs))
        _ = try NfTablesAttribute.renderInto(hookAttrs, &hookBuffer, offset: 0)
        #expect(
            hookBuffer
                == [UInt8](
                    hex:
                        "14000480"  // attr hdr (len=20 type=NFTA_CHAIN_HOOK|NLA_F_NESTED)
                        + "0800010000000003"  // NFTA_HOOK_HOOKNUM — BE32 3 (NF_INET_LOCAL_OUT)
                        + "08000200ffffff9c"  // NFTA_HOOK_PRIORITY — BE32 -100 (NF_IP_PRI_NAT_DST)
                )
        )
    }

    /// A single message is emitted as a `[BATCH_BEGIN, message, BATCH_END]`
    /// mini-batch; the bare name `nat` is namespaced to
    /// `containerization-nat`, and the table message carries no `NLM_F_CREATE`.
    @Test func buildSingleTableMiniBatch() throws {
        let tableMessage = NfTablesMessage.addTable(family: 2, name: "nat")

        let bytes = try NfTablesSession.buildBatch([tableMessage], pid: 0)

        let expected = [UInt8](
            hex:
                "14000000"  // nlh.len: 20
                + "10000100"  // nlh.type: NFNL_MSG_BATCH_BEGIN (0x10); flags: NLM_F_REQUEST
                + "00000000"  // nlh.seq: 0
                + "00000000"  // nlh.pid: 0
                + "0000000a"  // nfgenmsg: family=UNSPEC version=V0 res_id=0x000a (NFTABLES)
                + "38000000"  // nlmsghdr.len: 56
                + "000a0100"  // nlmsghdr.type: NFNL_SUBSYS_NFTABLES << 8|NFT_MSG_NEWTABLE (0x0a00); flags: REQUEST
                + "01000000"  // nlmsghdr.seq: 1
                + "00000000"  // nlmsghdr.pid: 0
                + "02000000"  // nfgenmsg: family=NFPROTO_IPV4 (2)
                + "19000100636f6e7461696e6572697a6174696f6e2d6e617400000000"  // NFTA_TABLE_NAME: "containerization-nat" (bare `nat` namespaced)
                + "0800020000000000"  // NFTA_TABLE_FLAGS: BE32 0
                + "14000000"  // nlh.len: 20
                + "11000500"  // nlh.type: NFNL_MSG_BATCH_END (0x11); flags: REQUEST|ACK
                + "02000000"  // nlh.seq: 2
                + "00000000"  // nlh.pid: 0
                + "0000000a"  // nfgenmsg: family=UNSPEC version=V0 res_id=0x000a (NFTABLES)
        )
        #expect(bytes.count == 96)
        #expect(bytes == expected)
    }

    /// `addChain` with an explicit non-default policy emits `NFTA_CHAIN_POLICY`
    /// (drop = 0) between the chain name and its hook type.
    @Test func buildSingleChainWithDropPolicy() throws {
        let chainMessage = NfTablesMessage.addChain(
            family: 2, table: "nat", chain: "output",
            options: ChainOptions(
                type: "nat",
                hook: NetfilterHook.NF_INET_LOCAL_OUT,
                priority: NetfilterHookPriority.NF_IP_PRI_NAT_DST,
                policy: NetfilterVerdict.NF_DROP))

        let bytes = try NfTablesSession.buildBatch([chainMessage], pid: 0)

        let expected = [UInt8](
            hex:
                "140000001000010000000000000000000000000a"  // BATCH_BEGIN nlh (20 B): len=20 type=0x10 flags=REQUEST seq=0; nfgen res_id=0x000a (NFTABLES)
                + "70000000030a01040100000000000000"  // NEWCHAIN nlmsghdr (16 B): len=112 type=0x0a03 flags=REQUEST|CREATE seq=1
                + "02000000"  // nfgenmsg (4 B): family=NFPROTO_IPV4 (2)
                + "19000100636f6e7461696e6572697a6174696f6e2d6e617400000000"  // NFTA_CHAIN_TABLE: "containerization-nat"
                + "1c000300636f6e7461696e6572697a6174696f6e2d6f757470757400"  // NFTA_CHAIN_NAME: "containerization-output"
                + "0800050000000000"  // NFTA_CHAIN_POLICY: BE32 0 (NF_DROP)
                + "080007006e617400"  // NFTA_CHAIN_TYPE: "nat"
                + "14000480"  // NFTA_CHAIN_HOOK: len=20 type=HOOK|NLA_F_NESTED
                + "0800010000000003"  // NFTA_HOOK_HOOKNUM: BE32 3 (NF_INET_LOCAL_OUT)
                + "08000200ffffff9c"  // NFTA_HOOK_PRIORITY: BE32 -100 (NF_IP_PRI_NAT_DST)
                + "140000001100050002000000000000000000000a"  // BATCH_END nlh (20 B): len=20 type=0x11 flags=REQUEST|ACK seq=2; nfgen res_id=0x000a
        )
        #expect(bytes.count == 152)
        #expect(bytes == expected)
    }

    /// A single UDP DNAT rule (`192.0.2.2:53` → `198.51.100.100:3053`)
    /// is encoded into the expected nftables expression list.
    @Test func buildSingleRule() throws {
        let ruleMessage = NfTablesMessage.addDnatRule(
            family: 2, table: "nat", chain: "output",
            rule: DNATRule(
                matchDaddr: try IPv4Address("192.0.2.2"), matchDport: 53,
                matchProto: IPProtocol.IPPROTO_UDP,
                dnatAddr: try IPv4Address("198.51.100.100"), dnatPort: 3053))

        let bytes = try NfTablesSession.buildBatch([ruleMessage], pid: 0)

        let expected = [UInt8](
            hex:
                "140000001000010000000000000000000000000a"  // BATCH_BEGIN nlh (20 B): len=20 type=0x10 flags=REQUEST seq=0; nfgen res_id=0x000a (NFTABLES)
                + "f0010000060a010c0100000000000000"  // NEWRULE nlmsghdr (16 B): len=496 type=0x0a06 flags=REQUEST|CREATE|APPEND seq=1
                + "02000000"  // nfgenmsg (4 B): family=NFPROTO_IPV4 (2)
                + "19000100636f6e7461696e6572697a6174696f6e2d6e617400000000"  // NFTA_RULE_TABLE: "containerization-nat"
                + "1c000200636f6e7461696e6572697a6174696f6e2d6f757470757400"  // NFTA_RULE_CHAIN: "containerization-output"
                + "a4010480"  // NFTA_RULE_EXPRESSIONS: len=420, NESTED (9 list elems)
                // expr 1 — payload: load the IPv4 daddr at byte 16 into the network header, 4 B → REG1
                + "34000180"  //   LIST_ELEM: len=52 type=NFTA_LIST_ELEM|NESTED
                + "0c0001007061796c6f616400"  //   NFTA_EXPR_NAME: "payload"
                + "24000280"  //   NFTA_EXPR_DATA (NESTED)
                + "0800010000000001"  //     NFTA_PAYLOAD_DREG: BE32 REG1
                + "0800020000000001"  //     NFTA_PAYLOAD_BASE: BE32 NFT_PAYLOAD_NETWORK_HEADER (1)
                + "0800030000000010"  //     NFTA_PAYLOAD_OFFSET: BE32 16
                + "0800040000000004"  //     NFTA_PAYLOAD_LEN: BE32 4
                // expr 2 — cmp: daddr == 192.0.2.2
                + "2c000180"  //   LIST_ELEM: len=44 type=NFTA_LIST_ELEM|NESTED
                + "08000100636d7000"  //   NFTA_EXPR_NAME: "cmp"
                + "20000280"  //   NFTA_EXPR_DATA (NESTED)
                + "0800010000000001"  //     NFTA_CMP_SREG: BE32 REG1
                + "0800020000000000"  //     NFTA_CMP_OP: BE32 NFT_CMP_EQ (0)
                + "0c000380"  //     NFTA_CMP_DATA (NESTED)
                + "08000100c0000202"  //       NFTA_DATA_VALUE: BE32 192.0.2.2
                // expr 3 — meta: load the L4 protocol → REG1
                + "24000180"  //   LIST_ELEM: len=36 type=NFTA_LIST_ELEM|NESTED
                + "090001006d65746100000000"  //   NFTA_EXPR_NAME: "meta"
                + "14000280"  //   NFTA_EXPR_DATA (NESTED)
                + "0800020000000010"  //     NFTA_META_KEY: BE32 NFT_META_L4PROTO (16)
                + "0800010000000001"  //     NFTA_META_DREG: BE32 REG1
                // expr 4 — cmp: l4proto == 17 (UDP)
                + "2c000180"  //   LIST_ELEM: len=44 type=NFTA_LIST_ELEM|NESTED
                + "08000100636d7000"  //   NFTA_EXPR_NAME: "cmp"
                + "20000280"  //   NFTA_EXPR_DATA (NESTED)
                + "0800010000000001"  //     NFTA_CMP_SREG: BE32 REG1
                + "0800020000000000"  //     NFTA_CMP_OP: BE32 NFT_CMP_EQ (0)
                + "0c000380"  //     NFTA_CMP_DATA (NESTED)
                + "0500010011000000"  //       NFTA_DATA_VALUE: 1 B = 0x11 (17)
                // expr 5 — payload: load the TCP/UDP dport at byte 2 into the transport header, 2 B → REG1
                + "34000180"  //   LIST_ELEM: len=52 type=NFTA_LIST_ELEM|NESTED
                + "0c0001007061796c6f616400"  //   NFTA_EXPR_NAME: "payload"
                + "24000280"  //   NFTA_EXPR_DATA (NESTED)
                + "0800010000000001"  //     NFTA_PAYLOAD_DREG: BE32 REG1
                + "0800020000000002"  //     NFTA_PAYLOAD_BASE: BE32 NFT_PAYLOAD_TRANSPORT_HEADER (2)
                + "0800030000000002"  //     NFTA_PAYLOAD_OFFSET: BE32 2
                + "0800040000000002"  //     NFTA_PAYLOAD_LEN: BE32 2
                // expr 6 — cmp: dport == 53
                + "2c000180"  //   LIST_ELEM: len=44 type=NFTA_LIST_ELEM|NESTED
                + "08000100636d7000"  //   NFTA_EXPR_NAME: "cmp"
                + "20000280"  //   NFTA_EXPR_DATA (NESTED)
                + "0800010000000001"  //     NFTA_CMP_SREG: BE32 REG1
                + "0800020000000000"  //     NFTA_CMP_OP: BE32 NFT_CMP_EQ (0)
                + "0c000380"  //     NFTA_CMP_DATA (NESTED)
                + "0600010000350000"  //       NFTA_DATA_VALUE: BE16 53
                // expr 7 — immediate: dnat ip → REG1
                + "2c000180"  //   LIST_ELEM: len=44 type=NFTA_LIST_ELEM|NESTED
                + "0e000100696d6d656469617465000000"  //   NFTA_EXPR_NAME: "immediate" (14 B attr + pad)
                + "18000280"  //   NFTA_EXPR_DATA (NESTED)
                + "0800010000000001"  //     NFTA_IMMEDIATE_DREG: BE32 REG1
                + "0c000280"  //     NFTA_IMMEDIATE_DATA (NESTED)
                + "08000100c6336464"  //       NFTA_DATA_VALUE: BE32 198.51.100.100
                // expr 8 — immediate: dnat port → REG2
                + "2c000180"  //   LIST_ELEM: len=44 type=NFTA_LIST_ELEM|NESTED
                + "0e000100696d6d656469617465000000"  //   NFTA_EXPR_NAME: "immediate" (14 B attr + pad)
                + "18000280"  //   NFTA_EXPR_DATA (NESTED)
                + "0800010000000002"  //     NFTA_IMMEDIATE_DREG: BE32 REG2
                + "0c000280"  //     NFTA_IMMEDIATE_DATA (NESTED)
                + "060001000bed0000"  //       NFTA_DATA_VALUE: BE16 3053
                // expr 9 — nat: DNAT REG1:REG2 (ip:port), PROTO_SPECIFIED
                + "38000180"  //   LIST_ELEM: len=56 type=NFTA_LIST_ELEM|NESTED
                + "080001006e617400"  //   NFTA_EXPR_NAME: "nat"
                + "2c000280"  //   NFTA_EXPR_DATA (NESTED)
                + "0800010000000001"  //     NFTA_NAT_TYPE: BE32 NFT_NAT_DNAT (1)
                + "0800020000000002"  //     NFTA_NAT_FAMILY: BE32 NFPROTO_IPV4 (2)
                + "0800030000000001"  //     NFTA_NAT_REG_ADDR_MIN: BE32 REG1
                + "0800050000000002"  //     NFTA_NAT_REG_PROTO_MIN: BE32 REG2
                + "0800070000000002"  //     NFTA_NAT_FLAGS: BE32 NF_NAT_RANGE_PROTO_SPECIFIED (2)
                + "140000001100050002000000000000000000000a"  // BATCH_END nlh (20 B): len=20 type=0x11 flags=REQUEST|ACK seq=2; nfgen res_id=0x000a
        )
        #expect(bytes.count == 536)
        #expect(bytes == expected)
    }

    /// A zero `NLMSG_ERROR` reply acknowledges a combined batch commit.
    @Test func batchSucceedsOnZeroAck() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.responses.append(ackOrErrorReply(error: 0, seq: 3))

        let session = NfTablesSession(socket: mockSocket)
        let messages: [NfTablesMessage] = [
            .addTable(family: 2, name: "nat"),
            .addChain(
                family: 2, table: "nat", chain: "output",
                options: ChainOptions(type: "nat", hook: 3, priority: -100, policy: 1)),
        ]

        try session.sendBatch(messages)

        #expect(mockSocket.requests.count == 1)
    }

    /// A non-zero `NLMSG_ERROR` reply makes the combined batch throw the
    /// kernel's error.
    @Test func batchThrowsOnError() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.responses.append(ackOrErrorReply(error: -2, seq: 2))

        let session = NfTablesSession(socket: mockSocket)
        let messages: [NfTablesMessage] = [
            .addTable(family: 2, name: "nat"),
            .addChain(
                family: 2, table: "not_nat", chain: "output",
                options: ChainOptions(type: "nat", hook: 3, priority: -100, policy: 1)),
        ]

        #expect(throws: NetlinkDataError.responseError(rc: -2)) {
            try session.sendBatch(messages)
        }
    }

    /// `addDnatToOutput` sends the whole batch as exactly one atomic send
    /// and requires a zero-ACK before returning.
    @Test func addDnatToOutputSendsSingleAtomicBatch() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.responses.append(ackOrErrorReply(error: 0, seq: 4))

        let session = NfTablesSession(socket: mockSocket)
        let rule = DNATRule(
            matchDaddr: try IPv4Address("198.51.100.100"), matchDport: 53, matchProto: 17,
            dnatAddr: try IPv4Address("192.168.64.1"), dnatPort: 3053)
        try session.addDnatToOutput(rules: [rule])

        #expect(mockSocket.requests.count == 1)
        let expected = try NfTablesSession.buildBatch(NfTablesSession.buildDnatMessages([rule]), pid: 0)
        #expect(mockSocket.requests[0] == expected)
    }

    /// A non-zero `NLMSG_ERROR` reply makes `addDnatToOutput` throw the kernel's error.
    @Test func addDnatToOutputThrowsOnError() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.responses.append(ackOrErrorReply(error: -2, seq: 3))

        let session = NfTablesSession(socket: mockSocket)
        let rule = DNATRule(
            matchDaddr: try IPv4Address("198.51.100.100"), matchDport: 53, matchProto: 17,
            dnatAddr: try IPv4Address("192.168.64.1"), dnatPort: 3053)

        #expect(throws: NetlinkDataError.responseError(rc: -2)) {
            try session.addDnatToOutput(rules: [rule])
        }
        #expect(mockSocket.requests.count == 1)
    }

    private func containsSubsequence(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= bytes.count else {
            return false
        }
        if needle.isEmpty {
            return true
        }
        return (0...(bytes.count - needle.count)).contains { start in
            bytes[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    /// Builds a capped `NLMSG_ERROR` reply carrying the given error code.
    private func ackOrErrorReply(error: Int32, seq: UInt32 = 0) -> [UInt8] {
        let errorBytes = withUnsafeBytes(of: error.littleEndian) { Array($0) }
        let seqBytes = withUnsafeBytes(of: seq.littleEndian) { Array($0) }
        return [
            0x24, 0x00, 0x00, 0x00,  // len = 36
            0x02, 0x00, 0x00, 0x01,  // NLMSG_ERROR, NLM_F_CAPPED
        ]
            + seqBytes
            + [0x00, 0x00, 0x00, 0x08]  // pid = 8
            + errorBytes
            + [UInt8](repeating: 0, count: 16)  // echoed nlmsghdr (dummy)
    }
}
