//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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
import ContainerizationOS
import Logging

/// `NetlinkSession` facilitates interacting with netlink via a provided `NetlinkSocket`. This is the
/// core high-level type offered to perform actions to the netlink surface in the kernel.
public struct NetlinkSession {
    private static let receiveDataLength = 65536
    private static let mtu: UInt32 = 1280
    private let socket: any NetlinkSocket
    private let log: Logger

    /// Creates a new `NetlinkSession`.
    /// - Parameters:
    ///   - socket: The `NetlinkSocket` to use for netlink interaction.
    ///   - log: The logger to use. The default value is `nil`.
    public init(socket: any NetlinkSocket, log: Logger? = nil) {
        self.socket = socket
        self.log = log ?? Logger(label: "com.apple.containerization.netlink")
    }

    /// Errors that may occur during netlink interaction.
    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case invalidIpAddress
        case invalidPrefixLength
        case unexpectedInfo(type: UInt16)
        case unexpectedOffset(offset: Int, size: Int)
        case unexpectedResidualPackets
        case unexpectedResultSet(count: Int, expected: Int)

        /// The description of the errors.
        public var description: String {
            switch self {
            case .invalidIpAddress:
                return "invalid IP address"
            case .invalidPrefixLength:
                return "invalid prefix length"
            case .unexpectedInfo(let type):
                return "unexpected response information, type = \(type)"
            case .unexpectedOffset(let offset, let size):
                return "unexpected buffer state, offset = \(offset), size = \(size)"
            case .unexpectedResidualPackets:
                return "unexpected residual response packets"
            case .unexpectedResultSet(let count, let expected):
                return "unexpected result set size, count = \(count), expected = \(expected)"
            }
        }
    }

    /// Performs a link set command on an interface.
    /// - Parameters:
    ///   - interface: The name of the interface.
    ///   - up: The value to set the interface state to.
    public func linkSet(interface: String, up: Bool) throws {
        // ip link set dev [interface] [up|down]
        let interfaceIndex = try getInterfaceIndex(interface)
        let mtuAttr = RTAttribute(
            len: UInt16(RTAttribute.size + MemoryLayout<UInt32>.size), type: LinkAttributeType.IFLA_MTU)
        let requestSize = NetlinkMessageHeader.size + InterfaceInfo.size + mtuAttr.paddedLen
        var requestBuffer = [UInt8](repeating: 0, count: requestSize)
        var requestOffset = 0

        let requestHeader = NetlinkMessageHeader(
            len: UInt32(requestBuffer.count),
            type: NetlinkType.RTM_NEWLINK,
            flags: NetlinkFlags.NLM_F_REQUEST | NetlinkFlags.NLM_F_ACK,
            pid: socket.pid)
        requestOffset = try requestHeader.appendBuffer(&requestBuffer, offset: requestOffset)

        let flags = up ? InterfaceFlags.IFF_UP : 0
        let requestInfo = InterfaceInfo(
            family: UInt8(AddressFamily.AF_PACKET),
            index: interfaceIndex,
            flags: flags,
            change: InterfaceFlags.DEFAULT_CHANGE)
        requestOffset = try requestInfo.appendBuffer(&requestBuffer, offset: requestOffset)

        requestOffset = try mtuAttr.appendBuffer(&requestBuffer, offset: requestOffset)
        guard
            let newRequestOffset = requestBuffer.copyIn(
                as: UInt32.self,
                value: Self.mtu,
                offset: requestOffset)
        else {
            throw NetlinkDataError.sendMarshalFailure
        }
        requestOffset = newRequestOffset

        guard requestOffset == requestSize else {
            throw Error.unexpectedOffset(offset: requestOffset, size: requestSize)
        }

        try sendRequest(buffer: &requestBuffer)
        let (infos, _) = try parseResponse(infoType: NetlinkType.RTM_NEWLINK) { InterfaceInfo() }
        guard infos.count == 0 else {
            throw Error.unexpectedResultSet(count: infos.count, expected: 0)
        }
    }

    /// Performs a link get command on an interface.
    /// Returns information about the interface.
    /// - Parameter interface: The name of the interface to query.
    public func linkGet(interface: String? = nil) throws -> [LinkResponse] {
        // ip link ip show
        let maskAttr = RTAttribute(
            len: UInt16(RTAttribute.size + MemoryLayout<UInt32>.size), type: LinkAttributeType.IFLA_EXT_MASK)
        let interfaceName = try interface.map { try getInterfaceName($0) }
        let interfaceNameAttr = interfaceName.map {
            RTAttribute(len: UInt16(RTAttribute.size + $0.count), type: LinkAttributeType.IFLA_EXT_IFNAME)
        }
        let requestSize =
            NetlinkMessageHeader.size + InterfaceInfo.size + maskAttr.paddedLen + (interfaceNameAttr?.paddedLen ?? 0)
        var requestBuffer = [UInt8](repeating: 0, count: requestSize)
        var requestOffset = 0

        let flags =
            interface != nil ? NetlinkFlags.NLM_F_REQUEST : (NetlinkFlags.NLM_F_REQUEST | NetlinkFlags.NLM_F_DUMP)
        let requestHeader = NetlinkMessageHeader(
            len: UInt32(requestBuffer.count),
            type: NetlinkType.RTM_GETLINK,
            flags: flags,
            pid: socket.pid)
        requestOffset = try requestHeader.appendBuffer(&requestBuffer, offset: requestOffset)

        let requestInfo = InterfaceInfo(
            family: UInt8(AddressFamily.AF_PACKET),
            index: 0,
            flags: InterfaceFlags.IFF_UP,
            change: InterfaceFlags.DEFAULT_CHANGE)
        requestOffset = try requestInfo.appendBuffer(&requestBuffer, offset: requestOffset)

        requestOffset = try maskAttr.appendBuffer(&requestBuffer, offset: requestOffset)
        guard
            var requestOffset = requestBuffer.copyIn(
                as: UInt32.self,
                value: LinkAttributeMaskFilter.RTEXT_FILTER_VF | LinkAttributeMaskFilter.RTEXT_FILTER_SKIP_STATS,
                offset: requestOffset)
        else {
            throw NetlinkDataError.sendMarshalFailure
        }

        if let interfaceNameAttr {
            if let interfaceName {
                requestOffset = try interfaceNameAttr.appendBuffer(&requestBuffer, offset: requestOffset)
                guard let updatedRequestOffset = requestBuffer.copyIn(buffer: interfaceName, offset: requestOffset)
                else {
                    throw NetlinkDataError.sendMarshalFailure
                }

                requestOffset = updatedRequestOffset
            }
        }

        guard requestOffset == requestSize else {
            throw Error.unexpectedOffset(offset: requestOffset, size: requestSize)
        }

        try sendRequest(buffer: &requestBuffer)
        let (infos, attrDataLists) = try parseResponse(infoType: NetlinkType.RTM_NEWLINK) { InterfaceInfo() }
        var linkResponses: [LinkResponse] = []
        for i in 0..<infos.count {
            linkResponses.append(LinkResponse(interfaceIndex: infos[i].index, attrDatas: attrDataLists[i]))
        }

        return linkResponses
    }

    /// Adds an IPv4 address to an interface.
    /// - Parameters:
    ///   - interface: The name of the interface.
    ///   - address: The IPv4 address to add.
    public func addressAdd(interface: String, address: String) throws {
        // ip addr add [addr] dev [interface]
        // ip address {add|change|replace} IFADDR dev IFNAME [ LIFETIME ] [ CONFFLAG-LIST ]
        // IFADDR := PREFIX | ADDR peer PREFIX
        //           [ broadcast ADDR ] [ anycast ADDR ]
        //           [ label IFNAME ] [ scope SCOPE-ID ] [ metric METRIC ]
        // SCOPE-ID := [ host | link | global | NUMBER ]
        // CONFFLAG-LIST := [ CONFFLAG-LIST ] CONFFLAG
        // CONFFLAG  := [ home | nodad | mngtmpaddr | noprefixroute | autojoin ]
        // LIFETIME := [ valid_lft LFT ] [ preferred_lft LFT ]
        // LFT := forever | SECONDS
        let parsed = try parseCIDR(cidr: address)
        let interfaceIndex = try getInterfaceIndex(interface)
        let ipAddressBytes = try IPv4Address(parsed.address).networkBytes
        let addressAttrSize = RTAttribute.size + MemoryLayout<UInt8>.size * ipAddressBytes.count
        let requestSize = NetlinkMessageHeader.size + AddressInfo.size + 2 * addressAttrSize
        var requestBuffer = [UInt8](repeating: 0, count: requestSize)
        var requestOffset = 0

        let header = NetlinkMessageHeader(
            len: UInt32(requestBuffer.count),
            type: NetlinkType.RTM_NEWADDR,
            flags: NetlinkFlags.NLM_F_REQUEST | NetlinkFlags.NLM_F_ACK | NetlinkFlags.NLM_F_EXCL
                | NetlinkFlags.NLM_F_CREATE,
            seq: 0,
            pid: socket.pid)
        requestOffset = try header.appendBuffer(&requestBuffer, offset: requestOffset)

        let requestInfo = AddressInfo(
            family: UInt8(AddressFamily.AF_INET),
            prefixLength: parsed.prefix,
            flags: 0,
            scope: NetlinkScope.RT_SCOPE_UNIVERSE,
            index: UInt32(interfaceIndex))
        requestOffset = try requestInfo.appendBuffer(&requestBuffer, offset: requestOffset)

        let ipLocalAttr = RTAttribute(len: UInt16(addressAttrSize), type: AddressAttributeType.IFA_LOCAL)
        requestOffset = try ipLocalAttr.appendBuffer(&requestBuffer, offset: requestOffset)
        guard var requestOffset = requestBuffer.copyIn(buffer: ipAddressBytes, offset: requestOffset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        let ipAddressAttr = RTAttribute(len: UInt16(addressAttrSize), type: AddressAttributeType.IFA_ADDRESS)
        requestOffset = try ipAddressAttr.appendBuffer(&requestBuffer, offset: requestOffset)
        guard let requestOffset = requestBuffer.copyIn(buffer: ipAddressBytes, offset: requestOffset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        guard requestOffset == requestSize else {
            throw Error.unexpectedOffset(offset: requestOffset, size: requestSize)
        }

        try sendRequest(buffer: &requestBuffer)
        let (infos, _) = try parseResponse(infoType: NetlinkType.RTM_NEWLINK) { AddressInfo() }
        guard infos.count == 0 else {
            throw Error.unexpectedResultSet(count: infos.count, expected: 0)
        }
    }

    private func parseCIDR(cidr: String) throws -> (address: String, prefix: UInt8) {
        let split = cidr.components(separatedBy: "/")
        guard split.count == 2 else {
            throw NetworkAddressError.invalidCIDR(cidr: cidr)
        }
        let address = split[0]
        guard let prefixLength = PrefixLength(split[1]) else {
            throw NetworkAddressError.invalidCIDR(cidr: cidr)
        }
        guard prefixLength >= 0 && prefixLength <= 32 else {
            throw NetworkAddressError.invalidCIDR(cidr: cidr)
        }
        return (address, prefixLength)
    }

    /// Adds a route to an interface.
    /// - Parameters:
    ///   - interface: The name of the interface.
    ///   - destinationAddress: The destination address to route to.
    ///   - srcAddr: The source address to route from.
    public func routeAdd(
        interface: String,
        destinationAddress: String,
        srcAddr: String
    ) throws {
        // ip route add [dest-cidr] dev [interface] src [src-addr] proto kernel
        let parsed = try parseCIDR(cidr: destinationAddress)
        let interfaceIndex = try getInterfaceIndex(interface)
        let dstAddrBytes = try IPv4Address(parsed.address).networkBytes
        let dstAddrAttrSize = RTAttribute.size + dstAddrBytes.count
        let srcAddrBytes = try IPv4Address(srcAddr).networkBytes
        let srcAddrAttrSize = RTAttribute.size + srcAddrBytes.count
        let interfaceAttrSize = RTAttribute.size + MemoryLayout<UInt32>.size
        let requestSize =
            NetlinkMessageHeader.size + RouteInfo.size + dstAddrAttrSize + srcAddrAttrSize + interfaceAttrSize
        var requestBuffer = [UInt8](repeating: 0, count: requestSize)
        var requestOffset = 0

        let header = NetlinkMessageHeader(
            len: UInt32(requestBuffer.count),
            type: NetlinkType.RTM_NEWROUTE,
            flags: NetlinkFlags.NLM_F_REQUEST | NetlinkFlags.NLM_F_ACK | NetlinkFlags.NLM_F_EXCL
                | NetlinkFlags.NLM_F_CREATE,
            pid: socket.pid)
        requestOffset = try header.appendBuffer(&requestBuffer, offset: requestOffset)

        let requestInfo = RouteInfo(
            family: UInt8(AddressFamily.AF_INET),
            dstLen: parsed.prefix,
            srcLen: 0,
            tos: 0,
            table: RouteTable.MAIN,
            proto: RouteProtocol.KERNEL,
            scope: RouteScope.LINK,
            type: RouteType.UNICAST,
            flags: 0)
        requestOffset = try requestInfo.appendBuffer(&requestBuffer, offset: requestOffset)

        let dstAddrAttr = RTAttribute(len: UInt16(dstAddrAttrSize), type: RouteAttributeType.DST)
        requestOffset = try dstAddrAttr.appendBuffer(&requestBuffer, offset: requestOffset)
        guard var requestOffset = requestBuffer.copyIn(buffer: dstAddrBytes, offset: requestOffset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        let srcAddrAttr = RTAttribute(len: UInt16(dstAddrAttrSize), type: RouteAttributeType.PREFSRC)
        requestOffset = try srcAddrAttr.appendBuffer(&requestBuffer, offset: requestOffset)
        guard var requestOffset = requestBuffer.copyIn(buffer: srcAddrBytes, offset: requestOffset) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        let interfaceAttr = RTAttribute(len: UInt16(interfaceAttrSize), type: RouteAttributeType.OIF)
        requestOffset = try interfaceAttr.appendBuffer(&requestBuffer, offset: requestOffset)
        guard
            let requestOffset = requestBuffer.copyIn(
                as: UInt32.self,
                value: UInt32(interfaceIndex),
                offset: requestOffset)
        else {
            throw NetlinkDataError.sendMarshalFailure
        }

        guard requestOffset == requestSize else {
            throw Error.unexpectedOffset(offset: requestOffset, size: requestSize)
        }

        try sendRequest(buffer: &requestBuffer)
        let (infos, _) = try parseResponse(infoType: NetlinkType.RTM_NEWLINK) { AddressInfo() }
        guard infos.count == 0 else {
            throw Error.unexpectedResultSet(count: infos.count, expected: 0)
        }
    }

    /// Adds a default route to an interface.
    /// - Parameters:
    ///   - interface: The name of the interface.
    ///   - gateway: The gateway address.
    public func routeAddDefault(
        interface: String,
        gateway: String
    ) throws {
        // ip route add default via [dst-address] src [src-address]
        let dstAddrBytes = try IPv4Address(gateway).networkBytes
        let dstAddrAttrSize = RTAttribute.size + dstAddrBytes.count

        let interfaceAttrSize = RTAttribute.size + MemoryLayout<UInt32>.size
        let interfaceIndex = try getInterfaceIndex(interface)
        let requestSize = NetlinkMessageHeader.size + RouteInfo.size + dstAddrAttrSize + interfaceAttrSize

        var requestBuffer = [UInt8](repeating: 0, count: requestSize)
        var requestOffset = 0

        let header = NetlinkMessageHeader(
            len: UInt32(requestBuffer.count),
            type: NetlinkType.RTM_NEWROUTE,
            flags: NetlinkFlags.NLM_F_REQUEST | NetlinkFlags.NLM_F_ACK | NetlinkFlags.NLM_F_EXCL
                | NetlinkFlags.NLM_F_CREATE,
            pid: socket.pid)
        requestOffset = try header.appendBuffer(&requestBuffer, offset: requestOffset)

        let requestInfo = RouteInfo(
            family: UInt8(AddressFamily.AF_INET),
            dstLen: 0,
            srcLen: 0,
            tos: 0,
            table: RouteTable.MAIN,
            proto: RouteProtocol.BOOT,
            scope: RouteScope.UNIVERSE,
            type: RouteType.UNICAST,
            flags: 0)
        requestOffset = try requestInfo.appendBuffer(&requestBuffer, offset: requestOffset)

        let dstAddrAttr = RTAttribute(len: UInt16(dstAddrAttrSize), type: RouteAttributeType.GATEWAY)
        requestOffset = try dstAddrAttr.appendBuffer(&requestBuffer, offset: requestOffset)
        guard var requestOffset = requestBuffer.copyIn(buffer: dstAddrBytes, offset: requestOffset) else {
            throw NetlinkDataError.sendMarshalFailure
        }
        let interfaceAttr = RTAttribute(len: UInt16(interfaceAttrSize), type: RouteAttributeType.OIF)
        requestOffset = try interfaceAttr.appendBuffer(&requestBuffer, offset: requestOffset)
        guard
            let requestOffset = requestBuffer.copyIn(
                as: UInt32.self,
                value: UInt32(interfaceIndex),
                offset: requestOffset)
        else {
            throw NetlinkDataError.sendMarshalFailure
        }

        guard requestOffset == requestSize else {
            throw Error.unexpectedOffset(offset: requestOffset, size: requestSize)
        }

        try sendRequest(buffer: &requestBuffer)
        let (infos, _) = try parseResponse(infoType: NetlinkType.RTM_NEWLINK) { AddressInfo() }
        guard infos.count == 0 else {
            throw Error.unexpectedResultSet(count: infos.count, expected: 0)
        }
    }

    private func getInterfaceName(_ interface: String) throws -> [UInt8] {
        guard let interfaceNameData = interface.data(using: .utf8) else {
            throw NetlinkDataError.sendMarshalFailure
        }

        var interfaceName = [UInt8](interfaceNameData)
        interfaceName.append(0)

        while interfaceName.count % MemoryLayout<UInt32>.size != 0 {
            interfaceName.append(0)
        }

        return interfaceName
    }

    private func getInterfaceIndex(_ interface: String) throws -> Int32 {
        let linkResponses = try linkGet(interface: interface)
        guard linkResponses.count == 1 else {
            throw Error.unexpectedResultSet(count: linkResponses.count, expected: 1)
        }

        return linkResponses[0].interfaceIndex
    }

    private func sendRequest(buffer: inout [UInt8]) throws {
        log.debug("SEND-LENGTH: \(buffer.count)")
        log.debug("SEND-DUMP: \(buffer[0..<buffer.count].hexEncodedString())")
        let sendLength = try socket.send(buf: &buffer, len: buffer.count, flags: 0)
        if sendLength != buffer.count {
            log.warning("sent length \(sendLength) not equal to packet length \(buffer.count)")
        }
    }

    private func receiveResponse() throws -> ([UInt8], Int) {
        var buffer = [UInt8](repeating: 0, count: Self.receiveDataLength)
        let size = try socket.recv(buf: &buffer, len: Self.receiveDataLength, flags: 0)
        log.debug("RECV-LENGTH: \(size)")
        log.debug("RECV-DUMP: \(buffer[0..<size].hexEncodedString())")
        return (buffer, size)
    }

    private func parseResponse<T: Bindable>(infoType: UInt16? = nil, _ infoProvider: () -> T) throws -> (
        [T], [[RTAttributeData]]
    ) {
        var infos: [T] = []
        var attrDataLists: [[RTAttributeData]] = []

        var moreResponses = false
        repeat {
            var (buffer, size) = try receiveResponse()
            let header: NetlinkMessageHeader
            var offset = 0

            (header, offset) = try parseHeader(buffer: &buffer, offset: offset)
            if let infoType {
                if header.type == infoType {
                    log.debug(
                        "RECV-INFO-DUMP:  dump = \(buffer[offset..<offset + InterfaceInfo.size].hexEncodedString())")
                    var info = infoProvider()
                    offset = try info.bindBuffer(&buffer, offset: offset)
                    log.debug("RECV-INFO: \(info)")

                    let attrDatas: [RTAttributeData]
                    (attrDatas, offset) = try parseAttributes(
                        buffer: &buffer,
                        offset: offset,
                        residualCount: size - offset)

                    infos.append(info)
                    attrDataLists.append(attrDatas)
                }
            } else if header.type != NetlinkType.NLMSG_DONE && header.type != NetlinkType.NLMSG_ERROR
                && header.type != NetlinkType.NLMSG_NOOP
            {
                throw Error.unexpectedInfo(type: header.type)
            }

            guard offset == size else {
                throw Error.unexpectedOffset(offset: offset, size: size)
            }

            moreResponses = header.moreResponses
        } while moreResponses

        return (infos, attrDataLists)
    }

    private func parseErrorCode(buffer: inout [UInt8], offset: Int) throws -> (Int32, Int) {
        guard let errorPtr = buffer.bind(as: Int32.self, offset: offset) else {
            throw NetlinkDataError.recvUnmarshalFailure
        }

        let rc = errorPtr.pointee
        log.debug("RECV-ERR-CODE: \(rc)")

        return (rc, offset + MemoryLayout<Int32>.size)
    }

    private func parseErrorResponse(buffer: inout [UInt8], offset: Int) throws -> Int {
        var (rc, offset) = try parseErrorCode(buffer: &buffer, offset: offset)
        log.debug(
            "RECV-ERR-HEADER-DUMP:  dump = \(buffer[offset..<offset + NetlinkMessageHeader.size].hexEncodedString())")
        var header = NetlinkMessageHeader()
        offset = try header.bindBuffer(&buffer, offset: offset)
        log.debug("RECV-ERR-HEADER: \(header))")

        guard rc == 0 else {
            throw NetlinkDataError.responseError(rc: rc)
        }

        return offset
    }

    private func parseHeader(buffer: inout [UInt8], offset: Int) throws -> (NetlinkMessageHeader, Int) {
        log.debug("RECV-HEADER-DUMP:  dump = \(buffer[offset..<offset + NetlinkMessageHeader.size].hexEncodedString())")
        var header = NetlinkMessageHeader()
        var offset = try header.bindBuffer(&buffer, offset: offset)
        log.debug("RECV-HEADER: \(header)")
        switch header.type {
        case NetlinkType.NLMSG_ERROR:
            offset = try parseErrorResponse(buffer: &buffer, offset: offset)
        case NetlinkType.NLMSG_DONE:
            let rc: Int32
            (rc, offset) = try parseErrorCode(buffer: &buffer, offset: offset)
            guard rc == 0 else {
                throw NetlinkDataError.responseError(rc: rc)
            }
        default:
            break
        }
        return (header, offset)
    }

    private func parseAttributes(buffer: inout [UInt8], offset: Int, residualCount: Int) throws -> (
        [RTAttributeData], Int
    ) {
        var attrDatas: [RTAttributeData] = []
        var offset = offset
        var residualCount = residualCount
        log.debug("RECV-RESIDUAL: \(residualCount)")

        while residualCount > 0 {
            var attr = RTAttribute()
            log.debug("  RECV-ATTR-DUMP: dump = \(buffer[offset..<offset + RTAttribute.size].hexEncodedString())")
            offset = try attr.bindBuffer(&buffer, offset: offset)
            log.debug("  RECV-ATTR: len = \(attr.len) type = \(attr.type)")
            let dataLen = Int(attr.len) - RTAttribute.size
            if dataLen >= 0 {
                log.debug("  RECV-ATTR-DATA-DUMP: dump = \(buffer[offset..<offset + dataLen].hexEncodedString())")
                attrDatas.append(RTAttributeData(attribute: attr, data: Array(buffer[offset..<offset + dataLen])))
            } else {
                attrDatas.append(RTAttributeData(attribute: attr, data: []))
            }
            residualCount -= Int(attr.paddedLen)
            offset += attr.paddedLen - RTAttribute.size
            log.debug("RECV-RESIDUAL: \(residualCount)")
        }

        return (attrDatas, offset)
    }
}
