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
import Foundation

/// Session for sending and receiving ICMPv4 messages.
public final class ICMPv4Session: Sendable {
    private static let receiveBufferSize = 65536

    private let socket: ICMPv4Socket

    public init() throws {
        self.socket = try ICMPv4Socket()
    }

    // MARK: - ICMPv4 Echo (Ping)

    /// Send an ICMPv4 echo request and wait for a reply
    /// - Parameters:
    ///   - host: The hostname or IP address to ping
    ///   - identifier: The identifier for the echo request (typically process ID)
    ///   - sequenceNumber: The sequence number for this ping
    ///   - payload: Optional payload data (default is 56-byte RTT timestamp)
    ///   - timeout: Maximum time to wait for a reply (default: 5 seconds)
    /// - Returns: Tuple of (reply, round-trip time in seconds, source address)
    public func echoRequest(
        ipAddress: IPv4Address,
        identifier: UInt16,
        sequenceNumber: UInt16
    ) throws {
        let totalSize = ICMPv4Header.size + Echo.size + EchoPayloadRTT.size
        var buffer = [UInt8](repeating: 0, count: totalSize)
        var offset = 0

        let header = ICMPv4Header(type: .echoRequest, code: 0)
        offset = try header.appendBuffer(&buffer, offset: offset)

        let echo = try Echo(identifier: identifier, sequenceNumber: sequenceNumber)
        offset = try echo.appendBuffer(&buffer, offset: offset)

        let payload = EchoPayloadRTT()
        offset = try payload.appendBuffer(&buffer, offset: offset)

        assert(offset == totalSize)

        let checksum = ICMPv4Header.checksum(buffer: buffer, offset: 0, length: totalSize)
        buffer[2] = UInt8((checksum >> 8) & 0xFF)
        buffer[3] = UInt8(checksum & 0xFF)
        _ = try socket.send(buffer: buffer, to: ipAddress)
    }

    public func recvHeader() throws -> (sourceAddr: IPv4Address, header: ICMPv4Header, bytes: [UInt8], length: Int, offset: Int) {
        var buffer = [UInt8](repeating: 0, count: Self.receiveBufferSize)
        let (bytesReceived, ipAddr) = try socket.receive(buffer: &buffer)

        // Skip IPv4 header
        guard bytesReceived > 0 else {
            throw ICMPError.bufferTooSmall(needed: 1, available: bytesReceived)
        }

        let ipHeaderLength = Int((buffer[0] & 0x0F)) * 4
        var offset = ipHeaderLength

        guard bytesReceived >= offset + ICMPv4Header.size else {
            throw ICMPError.bufferTooSmall(needed: offset + ICMPv4Header.size, available: bytesReceived)
        }

        var header = ICMPv4Header()
        offset = try header.bindBuffer(&buffer, offset: offset)

        return (sourceAddr: ipAddr, header: header, bytes: buffer, length: bytesReceived, offset: offset)
    }
}

/// Session for sending and receiving ICMPv6 messages.
public final class ICMPv6Session: Sendable {
    private static let receiveBufferSize = 65536

    private static let unspecifiedAddress = IPv6Address(0)
    private static func allRoutersMulticastAddress(zone: String?) -> IPv6Address {
        IPv6Address(0xFF02_0000_0000_0000_0000_0000_0000_0002, zone: zone)
    }

    private let socket: ICMPv6Socket

    public init() throws {
        self.socket = try ICMPv6Socket()
    }

    /// Send an ICMPv6 echo request and wait for a reply
    /// - Parameters:
    ///   - host: The hostname or IP address to ping
    ///   - identifier: The identifier for the echo request (typically process ID)
    ///   - sequenceNumber: The sequence number for this ping
    ///   - payload: Optional payload data (default is 56-byte RTT timestamp)
    ///   - timeout: Maximum time to wait for a reply (default: 5 seconds)
    /// - Returns: Tuple of (reply, round-trip time in seconds, source address)
    public func echoRequest(
        ipAddress: IPv6Address,
        identifier: UInt16,
        sequenceNumber: UInt16,
    ) throws {
        let totalSize = ICMPv6Header.size + Echo.size + EchoPayloadRTT.size
        var buffer = [UInt8](repeating: 0, count: totalSize)
        var offset = 0

        let header = ICMPv6Header(type: .echoRequest, code: 0)
        offset = try header.appendBuffer(&buffer, offset: offset)

        let echo = try Echo(identifier: identifier, sequenceNumber: sequenceNumber)
        offset = try echo.appendBuffer(&buffer, offset: offset)

        let payload = EchoPayloadRTT()
        offset = try payload.appendBuffer(&buffer, offset: offset)

        assert(offset == totalSize)

        _ = try socket.send(buffer: buffer, to: ipAddress)
    }

    public func routerSolicitation(linkLayerAddress: MACAddress?, interface: String?) throws {
        let totalSize: Int
        if linkLayerAddress == nil {
            totalSize = ICMPv6Header.size + MemoryLayout<UInt32>.size
        } else {
            totalSize = ICMPv6Header.size + MemoryLayout<UInt32>.size + NDOptionHeader.size + SourceLinkLayerAddress.size
        }

        var buffer = [UInt8](repeating: 0, count: totalSize)
        var offset = 0

        let header = ICMPv6Header(type: .routerSolicitation, code: 0)
        offset = try header.appendBuffer(&buffer, offset: offset)

        guard var offset = buffer.copyIn(as: UInt32.self, value: 0, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouterSolicitation", field: "reserved")
        }

        if let address = linkLayerAddress {
            let option = NDOption.sourceLinkLayerAddress(address)
            offset = try option.appendBuffer(&buffer, offset: offset)
        }

        assert(offset == totalSize)

        _ = try socket.send(buffer: buffer, to: Self.allRoutersMulticastAddress(zone: interface))
    }

    public func recvHeader() throws -> (sourceAddr: IPv6Address, header: ICMPv6Header, bytes: [UInt8], length: Int, offset: Int) {
        var buffer = [UInt8](repeating: 0, count: Self.receiveBufferSize)
        let (bytesReceived, ipAddr) = try socket.receive(buffer: &buffer)

        guard bytesReceived >= ICMPv6Header.size else {
            throw ICMPError.bufferTooSmall(needed: ICMPv6Header.size, available: bytesReceived)
        }

        var offset = 0
        var header = ICMPv6Header()
        offset = try header.bindBuffer(&buffer, offset: offset)

        return (sourceAddr: ipAddr, header: header, bytes: buffer, length: bytesReceived, offset: offset)
    }
}

extension ICMPv4Session {
    /// Receive and wait for a specific message type
    public func recv(type: ICMPv4MessageType, timeout: Duration = .seconds(5)) throws -> (sourceAddr: IPv4Address, header: ICMPv4Header, bytes: [UInt8], length: Int, offset: Int) {
        let deadline = Date.now + timeout / .seconds(1)
        while Date.now < deadline {
            let (addr, header, buffer, length, offset) = try recvHeader()
            if header.type == type {
                return (sourceAddr: addr, header: header, bytes: buffer, length: length, offset: offset)
            }
        }
        throw ICMPError.timeout
    }
}

extension ICMPv6Session {
    /// Receive and wait for a specific message type
    public func recv(type: ICMPv6MessageType, timeout: Duration = .seconds(5)) throws -> (sourceAddr: IPv6Address, header: ICMPv6Header, bytes: [UInt8], length: Int, offset: Int) {
        let deadline = Date.now + timeout / .seconds(1)
        while Date.now < deadline {
            let (addr, header, buffer, length, offset) = try recvHeader()
            if header.type == type {
                return (sourceAddr: addr, header: header, bytes: buffer, length: length, offset: offset)
            }
        }
        throw ICMPError.timeout
    }
}
