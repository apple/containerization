//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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
import Foundation

struct SocketType {
    static let SOCK_RAW: Int32 = 3
}

struct AddressFamily {
    static let AF_UNSPEC: UInt16 = 0
    static let AF_INET: UInt16 = 2
    static let AF_INET6: UInt16 = 10
    static let AF_NETLINK: UInt16 = 16
    static let AF_PACKET: UInt16 = 17
}

struct ArpHardware {
    static let ARPHRD_ETHER: UInt16 = 1
}

struct NetlinkProtocol {
    static let NETLINK_ROUTE: Int32 = 0
}

struct NetlinkType {
    static let NLMSG_NOOP: UInt16 = 1
    static let NLMSG_ERROR: UInt16 = 2
    static let NLMSG_DONE: UInt16 = 3
    static let NLMSG_OVERRUN: UInt16 = 4
    static let RTM_NEWLINK: UInt16 = 16
    static let RTM_DELLINK: UInt16 = 17
    static let RTM_GETLINK: UInt16 = 18
    static let RTM_NEWADDR: UInt16 = 20
    static let RTM_NEWROUTE: UInt16 = 24
}

struct NetlinkFlags {
    static let NLM_F_REQUEST: UInt16 = 0x01
    static let NLM_F_MULTI: UInt16 = 0x02
    static let NLM_F_ACK: UInt16 = 0x04
    static let NLM_F_ECHO: UInt16 = 0x08
    static let NLM_F_DUMP_INTR: UInt16 = 0x10
    static let NLM_F_DUMP_FILTERED: UInt16 = 0x20

    // GET request
    static let NLM_F_ROOT: UInt16 = 0x100
    static let NLM_F_MATCH: UInt16 = 0x200
    static let NLM_F_ATOMIC: UInt16 = 0x400
    static let NLM_F_DUMP: UInt16 = NetlinkFlags.NLM_F_ROOT | NetlinkFlags.NLM_F_MATCH

    // NEW request flags
    static let NLM_F_REPLACE: UInt16 = 0x100
    static let NLM_F_EXCL: UInt16 = 0x200
    static let NLM_F_CREATE: UInt16 = 0x400
    static let NLM_F_APPEND: UInt16 = 0x800
}

struct NetlinkScope {
    static let RT_SCOPE_UNIVERSE: UInt8 = 0
}

struct InterfaceFlags {
    static let IFF_UP: UInt32 = 1 << 0
    static let IFF_LOOPBACK: UInt32 = 1 << 3
    static let IFF_POINTOPOINT: UInt32 = 1 << 4
    static let DEFAULT_CHANGE: UInt32 = 0xffff_ffff
}

struct LinkAttributeType {
    static let IFLA_ADDRESS: UInt16 = 1
    static let IFLA_BROADCAST: UInt16 = 2
    static let IFLA_IFNAME: UInt16 = 3
    static let IFLA_MTU: UInt16 = 4
    static let IFLA_STATS64: UInt16 = 23
    static let IFLA_EXT_MASK: UInt16 = 29
}

struct LinkAttributeMaskFilter {
    static let RTEXT_FILTER_VF: UInt32 = 1 << 0
    static let RTEXT_FILTER_SKIP_STATS: UInt32 = 1 << 3
}

struct AddressAttributeType {
    // subnet mask
    static let IFA_ADDRESS: UInt16 = 1
    // IPv4 address
    static let IFA_LOCAL: UInt16 = 2
}

struct RouteTable {
    static let MAIN: UInt8 = 254
}

struct RouteProtocol {
    static let UNSPEC: UInt8 = 0
    static let REDIRECT: UInt8 = 1
    static let KERNEL: UInt8 = 2
    static let BOOT: UInt8 = 3
    static let STATIC: UInt8 = 4
}

struct RouteScope {
    static let UNIVERSE: UInt8 = 0
    static let LINK: UInt8 = 253
}

struct RouteType {
    static let UNSPEC: UInt8 = 0
    static let UNICAST: UInt8 = 1
}

struct RouteAttributeType {
    static let UNSPEC: UInt16 = 0
    static let DST: UInt16 = 1
    static let SRC: UInt16 = 2
    static let IIF: UInt16 = 3
    static let OIF: UInt16 = 4
    static let GATEWAY: UInt16 = 5
    static let PRIORITY: UInt16 = 6
    static let PREFSRC: UInt16 = 7
}

struct SockaddrNetlink: Bindable, Equatable {
    static let size = 12

    var family: UInt16
    var _pad: UInt16 = 0
    var pid: UInt32
    var groups: UInt32

    init(family: UInt16 = 0, pid: UInt32 = 0, groups: UInt32 = 0) {
        self.family = family
        self.pid = pid
        self.groups = groups
    }

    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt16.self, value: family, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "SockaddrNetlink", field: "family")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: 0, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "SockaddrNetlink", field: "_pad")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: pid, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "SockaddrNetlink", field: "pid")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: groups, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "SockaddrNetlink", field: "groups")
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "SockaddrNetlink", field: "family")
        }
        family = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "SockaddrNetlink", field: "_pad")
        }
        _pad = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "SockaddrNetlink", field: "pid")
        }
        pid = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "SockaddrNetlink", field: "groups")
        }
        groups = value

        return offset
    }
}

struct NetlinkMessageHeader: Bindable, Equatable {
    static let size = 16

    var len: UInt32
    var type: UInt16
    var flags: UInt16
    var seq: UInt32
    var pid: UInt32

    init(len: UInt32 = 0, type: UInt16 = 0, flags: UInt16 = 0, seq: UInt32? = nil, pid: UInt32 = 0) {
        self.len = len
        self.type = type
        self.flags = flags
        self.seq = seq ?? UInt32.random(in: 0..<UInt32.max)
        self.pid = pid
    }

    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt32.self, value: len, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NetlinkMessageHeader", field: "len")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: type, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NetlinkMessageHeader", field: "type")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: flags, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NetlinkMessageHeader", field: "flags")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: seq, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NetlinkMessageHeader", field: "seq")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: pid, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NetlinkMessageHeader", field: "pid")
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NetlinkMessageHeader", field: "len")
        }
        len = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NetlinkMessageHeader", field: "type")
        }
        type = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NetlinkMessageHeader", field: "flags")
        }
        flags = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NetlinkMessageHeader", field: "seq")
        }
        seq = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NetlinkMessageHeader", field: "pid")
        }
        pid = value

        return offset
    }

    var moreResponses: Bool {
        (self.flags & NetlinkFlags.NLM_F_MULTI) != 0
            && (self.type != NetlinkType.NLMSG_DONE && self.type != NetlinkType.NLMSG_ERROR
                && self.type != NetlinkType.NLMSG_OVERRUN)
    }
}

struct InterfaceInfo: Bindable, Equatable {
    static let size = 16

    var family: UInt8
    var _pad: UInt8 = 0
    var type: UInt16
    var index: Int32
    var flags: UInt32
    var change: UInt32

    init(
        family: UInt8 = UInt8(AddressFamily.AF_UNSPEC), type: UInt16 = 0, index: Int32 = 0, flags: UInt32 = 0,
        change: UInt32 = 0
    ) {
        self.family = family
        self.type = type
        self.index = index
        self.flags = flags
        self.change = change
    }

    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt8.self, value: family, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "InterfaceInfo", field: "family")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: _pad, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "InterfaceInfo", field: "_pad")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: type, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "InterfaceInfo", field: "type")
        }
        guard let offset = buffer.copyIn(as: Int32.self, value: index, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "InterfaceInfo", field: "index")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: flags, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "InterfaceInfo", field: "flags")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: change, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "InterfaceInfo", field: "change")
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "InterfaceInfo", field: "family")
        }
        family = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "InterfaceInfo", field: "_pad")
        }
        _pad = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "InterfaceInfo", field: "type")
        }
        type = value

        guard let (offset, value) = buffer.copyOut(as: Int32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "InterfaceInfo", field: "index")
        }
        index = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "InterfaceInfo", field: "flags")
        }
        flags = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "InterfaceInfo", field: "change")
        }
        change = value

        return offset
    }
}

struct AddressInfo: Bindable, Equatable {
    static let size = 8

    var family: UInt8
    var prefixLength: UInt8
    var flags: UInt8
    var scope: UInt8
    var index: UInt32

    init(
        family: UInt8 = UInt8(AddressFamily.AF_UNSPEC), prefixLength: UInt8 = 32, flags: UInt8 = 0, scope: UInt8 = 0,
        index: UInt32 = 0
    ) {
        self.family = family
        self.prefixLength = prefixLength
        self.flags = flags
        self.scope = scope
        self.index = index
    }

    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt8.self, value: family, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "AddressInfo", field: "family")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: prefixLength, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "AddressInfo", field: "prefixLength")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: flags, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "AddressInfo", field: "flags")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: scope, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "AddressInfo", field: "scope")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: index, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "AddressInfo", field: "index")
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "AddressInfo", field: "family")
        }
        family = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "AddressInfo", field: "prefixLength")
        }
        prefixLength = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "AddressInfo", field: "flags")
        }
        flags = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "AddressInfo", field: "scope")
        }
        scope = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "AddressInfo", field: "index")
        }
        index = value

        return offset
    }
}

struct RouteInfo: Bindable, Equatable {
    static let size = 12

    var family: UInt8
    var dstLen: UInt8
    var srcLen: UInt8
    var tos: UInt8
    var table: UInt8
    var proto: UInt8
    var scope: UInt8
    var type: UInt8
    var flags: UInt32

    init(
        family: UInt8 = UInt8(AddressFamily.AF_INET),
        dstLen: UInt8,
        srcLen: UInt8,
        tos: UInt8,
        table: UInt8,
        proto: UInt8,
        scope: UInt8,
        type: UInt8,
        flags: UInt32
    ) {
        self.family = family
        self.dstLen = dstLen
        self.srcLen = srcLen
        self.tos = tos
        self.table = table
        self.proto = proto
        self.scope = scope
        self.type = type
        self.flags = flags
    }

    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt8.self, value: family, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouteInfo", field: "family")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: dstLen, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouteInfo", field: "dstLen")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: srcLen, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouteInfo", field: "srcLen")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: tos, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouteInfo", field: "tos")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: table, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouteInfo", field: "table")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: proto, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouteInfo", field: "proto")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: scope, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouteInfo", field: "scope")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: type, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouteInfo", field: "type")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: flags, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouteInfo", field: "flags")
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouteInfo", field: "family")
        }
        family = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouteInfo", field: "dstLen")
        }
        dstLen = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouteInfo", field: "srcLen")
        }
        srcLen = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouteInfo", field: "tos")
        }
        tos = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouteInfo", field: "table")
        }
        table = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouteInfo", field: "proto")
        }
        proto = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouteInfo", field: "scope")
        }
        scope = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouteInfo", field: "type")
        }
        type = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouteInfo", field: "flags")
        }
        flags = value

        return offset
    }
}

/// A route information.
public struct RTAttribute: Bindable, Equatable {
    package static let size = 4

    public var len: UInt16
    public var type: UInt16
    public var paddedLen: Int { Int(((len + 3) >> 2) << 2) }

    init(len: UInt16 = 0, type: UInt16 = 0) {
        self.len = len
        self.type = type
    }

    package func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt16.self, value: len, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RTAttribute", field: "len")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: type, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RTAttribute", field: "type")
        }

        return offset
    }

    package mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RTAttribute", field: "len")
        }
        len = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RTAttribute", field: "type")
        }
        type = value

        return offset
    }
}

/// A route information with data.
public struct RTAttributeData {
    public let attribute: RTAttribute
    public let data: [UInt8]
}

/// A response from the get link command.
public struct LinkResponse {
    public let interfaceIndex: Int32
    public let interfaceFlags: UInt32
    public let interfaceType: UInt16
    public let attrDatas: [RTAttributeData]

    public var isLoopback: Bool {
        (interfaceFlags & InterfaceFlags.IFF_LOOPBACK) != 0
    }

    public var isEthernet: Bool {
        interfaceType == ArpHardware.ARPHRD_ETHER
            && (interfaceFlags & (InterfaceFlags.IFF_LOOPBACK | InterfaceFlags.IFF_POINTOPOINT)) == 0
    }

    public var address: [UInt8]? {
        attrDatas
            .filter { $0.attribute.type == LinkAttributeType.IFLA_ADDRESS }
            .first
            .map { $0.data }
    }

    /// Extract network interface statistics from the response attributes
    public func getStatistics() throws -> LinkStatistics64? {
        for attrData in attrDatas {
            if attrData.attribute.type == LinkAttributeType.IFLA_STATS64 {
                var stats = LinkStatistics64()
                var buffer = attrData.data
                _ = try stats.bindBuffer(&buffer, offset: 0)
                return stats
            }
        }

        return nil
    }
}

/// Network interface statistics (64-bit version)
public struct LinkStatistics64: Bindable, Equatable {
    package static let size = 23 * 8

    public var rxPackets: UInt64
    public var txPackets: UInt64
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var rxErrors: UInt64
    public var txErrors: UInt64
    public var rxDropped: UInt64
    public var txDropped: UInt64
    public var multicast: UInt64
    public var collisions: UInt64
    public var rxLengthErrors: UInt64
    public var rxOverErrors: UInt64
    public var rxCrcErrors: UInt64
    public var rxFrameErrors: UInt64
    public var rxFifoErrors: UInt64
    public var rxMissedErrors: UInt64
    public var txAbortedErrors: UInt64
    public var txCarrierErrors: UInt64
    public var txFifoErrors: UInt64
    public var txHeartbeatErrors: UInt64
    public var txWindowErrors: UInt64
    public var rxCompressed: UInt64
    public var txCompressed: UInt64

    public init() {
        self.rxPackets = 0
        self.txPackets = 0
        self.rxBytes = 0
        self.txBytes = 0
        self.rxErrors = 0
        self.txErrors = 0
        self.rxDropped = 0
        self.txDropped = 0
        self.multicast = 0
        self.collisions = 0
        self.rxLengthErrors = 0
        self.rxOverErrors = 0
        self.rxCrcErrors = 0
        self.rxFrameErrors = 0
        self.rxFifoErrors = 0
        self.rxMissedErrors = 0
        self.txAbortedErrors = 0
        self.txCarrierErrors = 0
        self.txFifoErrors = 0
        self.txHeartbeatErrors = 0
        self.txWindowErrors = 0
        self.rxCompressed = 0
        self.txCompressed = 0
    }

    package func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxPackets, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxPackets")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txPackets, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txPackets")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxBytes, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxBytes")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txBytes, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txBytes")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxDropped, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxDropped")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txDropped, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txDropped")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: multicast, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "multicast")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: collisions, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "collisions")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxLengthErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxLengthErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxOverErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxOverErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxCrcErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxCrcErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxFrameErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxFrameErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxFifoErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxFifoErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxMissedErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxMissedErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txAbortedErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txAbortedErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txCarrierErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txCarrierErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txFifoErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txFifoErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txHeartbeatErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txHeartbeatErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txWindowErrors, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txWindowErrors")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: rxCompressed, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "rxCompressed")
        }
        guard let offset = buffer.copyIn(as: UInt64.self, value: txCompressed, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "LinkStatistics64", field: "txCompressed")
        }

        return offset
    }

    package mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxPackets")
        }
        rxPackets = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txPackets")
        }
        txPackets = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxBytes")
        }
        rxBytes = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txBytes")
        }
        txBytes = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxErrors")
        }
        rxErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txErrors")
        }
        txErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxDropped")
        }
        rxDropped = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txDropped")
        }
        txDropped = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "multicast")
        }
        multicast = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "collisions")
        }
        collisions = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxLengthErrors")
        }
        rxLengthErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxOverErrors")
        }
        rxOverErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxCrcErrors")
        }
        rxCrcErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxFrameErrors")
        }
        rxFrameErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxFifoErrors")
        }
        rxFifoErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxMissedErrors")
        }
        rxMissedErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txAbortedErrors")
        }
        txAbortedErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txCarrierErrors")
        }
        txCarrierErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txFifoErrors")
        }
        txFifoErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txHeartbeatErrors")
        }
        txHeartbeatErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txWindowErrors")
        }
        txWindowErrors = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "rxCompressed")
        }
        rxCompressed = value

        guard let (offset, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "LinkStatistics64", field: "txCompressed")
        }
        txCompressed = value

        return offset
    }
}

/// Errors thrown when parsing netlink data.
public enum NetlinkDataError: Swift.Error, CustomStringConvertible, Equatable {
    case responseError(rc: Int32)
    case unsupportedPlatform

    /// The description of the errors.
    public var description: String {
        switch self {
        case .responseError(let rc):
            return "netlink response indicates error, rc = \(rc)"
        case .unsupportedPlatform:
            return "unsupported platform"
        }
    }
}
