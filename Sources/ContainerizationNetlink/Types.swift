//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
    static let DEFAULT_CHANGE: UInt32 = 0xffff_ffff
}

struct LinkAttributeType {
    static let IFLA_EXT_IFNAME: UInt16 = 3
    static let IFLA_MTU: UInt16 = 4
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

protocol Bindable: Equatable {
    static var size: Int { get }
    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int
    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int
}

struct SockaddrNetlink: Bindable {
    static let size = 12

    var family: UInt16
    var pad: UInt16 = 0
    var pid: UInt32
    var groups: UInt32

    init(family: UInt16 = 0, pid: UInt32 = 0, groups: UInt32 = 0) {
        self.family = family
        self.pid = pid
        self.groups = groups
    }

    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt16.self, value: family, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: pid, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: groups, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        family = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        pid = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        groups = value

        return offset + Self.size
    }
}

struct NetlinkMessageHeader: Bindable {
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
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: type, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: flags, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: seq, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: pid, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        len = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        type = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        flags = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        seq = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
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

struct InterfaceInfo: Bindable {
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
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: _pad, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: type, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: Int32.self, value: index, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: flags, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: change, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        family = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        _pad = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        type = value

        guard let (offset, value) = buffer.copyOut(as: Int32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        index = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        flags = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        change = value

        return offset
    }
}

struct AddressInfo: Bindable {
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
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: prefixLength, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: flags, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: scope, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: index, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        family = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        prefixLength = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        flags = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        scope = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        index = value

        return offset
    }
}

struct RouteInfo: Bindable {
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
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: dstLen, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: srcLen, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: tos, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: table, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: proto, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: scope, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: type, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: flags, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        family = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        dstLen = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        srcLen = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        tos = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        table = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        proto = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        scope = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        type = value

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        flags = value

        return offset
    }
}

/// A route information.
public struct RTAttribute: Bindable {
    static let size = 4

    public var len: UInt16
    public var type: UInt16
    public var paddedLen: Int { Int(((len + 3) >> 2) << 2) }

    init(len: UInt16 = 0, type: UInt16 = 0) {
        self.len = len
        self.type = type
    }

    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let offset = buffer.copyIn(as: UInt16.self, value: len, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: type, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        return offset
    }

    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        len = value

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw NetlinkDataError.sendMarshalFailure
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
    public let attrDatas: [RTAttributeData]
}

/// Errors thrown when parsing netlink data.
public enum NetlinkDataError: Swift.Error, CustomStringConvertible, Equatable {
    case sendMarshalFailure
    case recvUnmarshalFailure
    case responseError(rc: Int32)
    case unsupportedPlatform

    /// The description of the errors.
    public var description: String {
        switch self {
        case .sendMarshalFailure:
            return "could not marshal netlink packet"
        case .recvUnmarshalFailure:
            return "could not unmarshal netlink packet"
        case .responseError(let rc):
            return "netlink response indicates error, rc = \(rc)"
        case .unsupportedPlatform:
            return "unsupported platform"
        }
    }
}
