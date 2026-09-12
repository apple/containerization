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

struct NetfilterFamily {
    static let NFPROTO_UNSPEC: UInt8 = 0
    static let NFPROTO_IPV4: UInt8 = 2
}

/// Linux `IPPROTO_*` constants used to match the L4 protocol in nftables rules.
public struct IPProtocol {
    public static let IPPROTO_TCP: UInt8 = 6
    public static let IPPROTO_UDP: UInt8 = 17
}

struct NetfilterVerdict {
    static let NF_DROP: UInt32 = 0
    static let NF_ACCEPT: UInt32 = 1
}

struct NetfilterHook {
    static let NF_INET_PRE_ROUTING: UInt8 = 0
    static let NF_INET_LOCAL_IN: UInt8 = 1
    static let NF_INET_FORWARD: UInt8 = 2
    static let NF_INET_LOCAL_OUT: UInt8 = 3
    static let NF_INET_POST_ROUTING: UInt8 = 4
}

struct NetfilterHookPriority {
    static let NF_IP_PRI_NAT_DST: Int32 = -100
}

struct NetfilterNatRange {
    static let NF_NAT_RANGE_PROTO_SPECIFIED: UInt32 = 2
}

struct NfNetlinkVersion {
    static let NFNETLINK_V0: UInt8 = 0
}

struct NfNetlinkSubsystem {
    static let NFNL_SUBSYS_NFTABLES: UInt16 = 10
}

struct NfNetlinkBatchMessage {
    static let NFNL_MSG_BATCH_BEGIN: UInt16 = 0x10
    static let NFNL_MSG_BATCH_END: UInt16 = 0x11
}

struct NfTablesMessageType {
    static let NFT_MSG_NEWTABLE: UInt16 = 0
    static let NFT_MSG_NEWCHAIN: UInt16 = 3
    static let NFT_MSG_NEWRULE: UInt16 = 6
}

struct NfTablesRegister {
    static let NFT_REG_1: UInt32 = 1
    static let NFT_REG_2: UInt32 = 2
}

struct NfTablesCompareOp {
    static let NFT_CMP_EQ: UInt32 = 0
}

struct NfTablesPayloadBase {
    static let NFT_PAYLOAD_NETWORK_HEADER: UInt32 = 1
    static let NFT_PAYLOAD_TRANSPORT_HEADER: UInt32 = 2
}

struct NfTablesMetaKey {
    static let NFT_META_L4PROTO: UInt32 = 16
}

struct NfTablesNatType {
    static let NFT_NAT_SNAT: UInt32 = 0
    static let NFT_NAT_DNAT: UInt32 = 1
}

/// The `nlattr` header for nf_tables attributes, a concrete
/// ``NetlinkAttribute`` distinct from the route-family `RTAttribute`.
struct NfTablesAttributeHeader: NetlinkAttribute, Equatable {
    var len: UInt16
    var type: UInt16

    init(len: UInt16 = 0, type: UInt16 = 0) {
        self.len = len
        self.type = type
    }
}

/// A single nf_tables attribute to serialize, built by its constructors
/// (`string`, `bytes`, `data`, `bigEndian`, `nested`). `len`/`type` are fixed
/// at construction; `render(_:)` writes the whole tree into one buffer.
struct NfTablesAttribute: Equatable {
    /// The payload of an attribute: leaf bytes (big-endian scalar, bytes, or
    /// NUL-terminated string) or the children of a nested attribute, mutually
    /// exclusive by construction.
    enum Payload: Equatable {
        /// Pre-encoded wire bytes (see the attribute factories).
        case raw([UInt8])
        case nested([NfTablesAttribute])

        /// On-wire payload size.
        var size: Int {
            switch self {
            case .raw(let bytes): bytes.count
            case .nested(let children): children.reduce(0) { $0 + $1.paddedLen }
            }
        }

        /// Writes the payload at `offset`. The caller's buffer is pre-zeroed,
        /// so NLA padding needs no explicit write.
        func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
            switch self {
            case .raw(let bytes):
                guard let after = buffer.copyIn(buffer: bytes, offset: offset) else {
                    throw BindError.sendMarshalFailure(type: "NfTablesAttribute", field: "payload")
                }
                return after
            case .nested(let children):
                var offset = offset
                for child in children {
                    offset = try child.appendBuffer(&buffer, offset: offset)
                }
                return offset
            }
        }
    }

    let len: UInt16
    let type: UInt16
    let payload: Payload

    private init(len: UInt16, type: UInt16, payload: Payload) {
        self.len = len
        self.type = type
        self.payload = payload
    }

    /// A big-endian scalar attribute (ports, registers, hook priorities).
    static func bigEndian<T: FixedWidthInteger>(_ type: UInt16, _ value: T) -> NfTablesAttribute {
        let payload = Payload.raw(withUnsafeBytes(of: value.bigEndian) { Array($0) })
        return NfTablesAttribute(len: UInt16(NfTablesAttributeHeader.size + payload.size), type: type, payload: payload)
    }

    static func string(_ type: UInt16, _ value: String) -> NfTablesAttribute {
        let payload = Payload.raw(Array(value.utf8) + [0])  // NUL-terminated, like kernel strings
        return NfTablesAttribute(len: UInt16(NfTablesAttributeHeader.size + payload.size), type: type, payload: payload)
    }

    static func bytes(_ type: UInt16, _ value: [UInt8]) -> NfTablesAttribute {
        let payload = Payload.raw(value)
        return NfTablesAttribute(len: UInt16(NfTablesAttributeHeader.size + payload.size), type: type, payload: payload)
    }

    static func data(_ type: UInt16, _ bytes: [UInt8]) -> NfTablesAttribute {
        nested(type, [.bytes(DataAttributeType.VALUE, bytes)])
    }

    static func data<T: FixedWidthInteger>(_ type: UInt16, _ value: T) -> NfTablesAttribute {
        nested(type, [.bigEndian(DataAttributeType.VALUE, value)])
    }

    /// One rule expression: `NFTA_LIST_ELEM { NAME, DATA { ... } }`.
    static func listElement(name: String, body: [NfTablesAttribute]) -> NfTablesAttribute {
        nested(
            ListAttributeType.ELEM,
            [
                .string(ExpressionAttributeType.NAME, name),
                .nested(ExpressionAttributeType.DATA, body),
            ])
    }

    /// A nested attribute; its length is the NLA-4-aligned sum of its children's.
    static func nested(_ type: UInt16, _ children: [NfTablesAttribute]) -> NfTablesAttribute {
        let payload = Payload.nested(children)
        return NfTablesAttribute(
            len: UInt16(NfTablesAttributeHeader.size + payload.size), type: type | NetlinkAttributeFlags.NLA_F_NESTED, payload: payload)
    }

    /// The NLA-4-aligned on-wire size of this attribute.
    var paddedLen: Int { Int(((len + 3) >> 2) << 2) }

    /// Writes this attribute at `offset`. The caller's buffer is pre-zeroed,
    /// so trailing padding needs no explicit write.
    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let padded = paddedLen
        guard offset + padded <= buffer.count else {
            throw BindError.sendMarshalFailure(type: "NfTablesAttribute", field: "payload")
        }
        let header = NfTablesAttributeHeader(len: len, type: type)
        let start = offset
        var offset = try header.appendBuffer(&buffer, offset: offset)
        offset = try payload.appendBuffer(&buffer, offset: offset)
        return start + padded
    }

    /// Total padded length of `attrs`.
    static func renderSize(_ attrs: [NfTablesAttribute]) -> Int {
        attrs.reduce(0) { $0 + $1.paddedLen }
    }

    static func renderInto(_ attrs: [NfTablesAttribute], _ buffer: inout [UInt8], offset: Int) throws -> Int {
        var offset = offset
        for attr in attrs {
            offset = try attr.appendBuffer(&buffer, offset: offset)
        }
        return offset
    }
}

/// The 4-byte `nfgenmsg` header preceding every nfnetlink payload. Its 16-bit
/// `res_id` is big-endian, unlike the little-endian `nlmsghdr`/`nlattr`.
struct NfNetlinkGenMessage: Bindable, Equatable {
    static let size = 4

    var family: UInt8
    var version: UInt8
    var resID: UInt16

    init(family: UInt8 = NetfilterFamily.NFPROTO_UNSPEC, version: UInt8 = NfNetlinkVersion.NFNETLINK_V0, resID: UInt16 = 0) {
        self.family = family
        self.version = version
        self.resID = resID
    }

    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt8.self, value: family, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NfNetlinkGenMessage", field: "family")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: version, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NfNetlinkGenMessage", field: "version")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: resID.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NfNetlinkGenMessage", field: "res_id")
        }
        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NfNetlinkGenMessage", field: "family")
        }
        family = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NfNetlinkGenMessage", field: "version")
        }
        version = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NfNetlinkGenMessage", field: "res_id")
        }
        resID = value.bigEndian

        return offset
    }
}

struct TableAttributeType {
    static let NAME: UInt16 = 1
    static let FLAGS: UInt16 = 2
}

struct ChainAttributeType {
    static let TABLE: UInt16 = 1
    static let NAME: UInt16 = 3
    static let HOOK: UInt16 = 4
    static let POLICY: UInt16 = 5
    static let TYPE: UInt16 = 7
}

struct HookAttributeType {
    static let HOOKNUM: UInt16 = 1
    static let PRIORITY: UInt16 = 2
    static let DEV: UInt16 = 3
    static let DEVS: UInt16 = 4
}

struct RuleAttributeType {
    static let TABLE: UInt16 = 1
    static let CHAIN: UInt16 = 2
    static let EXPRESSIONS: UInt16 = 4
}

struct ListAttributeType {
    static let ELEM: UInt16 = 1
}

struct ExpressionAttributeType {
    static let NAME: UInt16 = 1
    static let DATA: UInt16 = 2
}

struct PayloadAttributeType {
    static let DREG: UInt16 = 1
    static let BASE: UInt16 = 2
    static let OFFSET: UInt16 = 3
    static let LEN: UInt16 = 4
}

struct CompareAttributeType {
    static let SREG: UInt16 = 1
    static let OP: UInt16 = 2
    static let DATA: UInt16 = 3
}

struct MetaAttributeType {
    static let DREG: UInt16 = 1
    static let KEY: UInt16 = 2
    static let SREG: UInt16 = 3
}

struct ImmediateAttributeType {
    static let DREG: UInt16 = 1
    static let DATA: UInt16 = 2
}

struct NatAttributeType {
    static let TYPE: UInt16 = 1
    static let FAMILY: UInt16 = 2
    static let REG_ADDR_MIN: UInt16 = 3
    static let REG_ADDR_MAX: UInt16 = 4
    static let REG_PROTO_MIN: UInt16 = 5
    static let REG_PROTO_MAX: UInt16 = 6
    static let FLAGS: UInt16 = 7
}

struct DataAttributeType {
    static let VALUE: UInt16 = 1
    static let VERDICT: UInt16 = 2
}
