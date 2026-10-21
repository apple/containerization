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

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A protocol for interacting with a netlink socket.
public protocol NetlinkSocket {
    var pid: UInt32 { get }
    func send(buf: UnsafeRawPointer!, len: Int, flags: Int32) throws -> Int
    func recv(buf: UnsafeMutableRawPointer!, len: Int, flags: Int32) throws -> Int
}

/// A netlink socket provider.
public typealias NetlinkSocketProvider = () throws -> any NetlinkSocket

/// Errors thrown when interacting with a netlink socket.
public enum NetlinkSocketError: Swift.Error, CustomStringConvertible, Equatable {
    case socketFailure(rc: Int32)
    case bindFailure(rc: Int32)
    case socketNameFailure(rc: Int32)
    case invalidSocketNameLength(expected: socklen_t, actual: socklen_t)
    case invalidSocketNameFamily(expected: UInt16, actual: UInt16)
    case zeroSocketPortIdentifier
    case sendFailure(rc: Int32)
    case recvFailure(rc: Int32)
    case notImplemented

    /// The description of the errors.
    public var description: String {
        switch self {
        case .socketFailure(let rc):
            return "could not create netlink socket, rc = \(rc)"
        case .bindFailure(let rc):
            return "could not bind netlink socket, rc = \(rc)"
        case .socketNameFailure(let rc):
            return "could not get netlink socket name, rc = \(rc)"
        case .invalidSocketNameLength(let expected, let actual):
            return "invalid netlink socket address length, expected \(expected) bytes, got \(actual)"
        case .invalidSocketNameFamily(let expected, let actual):
            return "invalid netlink socket address family, expected \(expected), got \(actual)"
        case .zeroSocketPortIdentifier:
            return "invalid netlink socket port identifier, expected a nonzero value, got 0"
        case .sendFailure(let rc):
            return "could not send netlink packet, rc = \(rc)"
        case .recvFailure(let rc):
            return "could not receive netlink packet, rc = \(rc)"
        case .notImplemented:
            return "socket function not implemented for platform"
        }
    }
}

extension SockaddrNetlink {
    /// Validates the address returned by getsockname before accepting its assigned port identifier.
    static func boundPortIdentifier(buffer: inout [UInt8], length: socklen_t) throws -> UInt32 {
        guard length == socklen_t(buffer.count) else {
            throw NetlinkSocketError.invalidSocketNameLength(expected: socklen_t(buffer.count), actual: length)
        }

        var address = SockaddrNetlink()
        _ = try address.bindBuffer(&buffer, offset: 0)
        guard address.family == AddressFamily.AF_NETLINK else {
            throw NetlinkSocketError.invalidSocketNameFamily(expected: AddressFamily.AF_NETLINK, actual: address.family)
        }
        guard address.pid != 0 else {
            throw NetlinkSocketError.zeroSocketPortIdentifier
        }
        return address.pid
    }
}

#if os(Linux)
#if canImport(Musl)
let osSocket = Musl.socket
let osBind = Musl.bind
let osGetsockname = Musl.getsockname
let osSend = Musl.send
let osRecv = Musl.recv
#elseif canImport(Glibc)
let osSocket = Glibc.socket
let osBind = Glibc.bind
let osGetsockname = Glibc.getsockname
let osSend = Glibc.send
let osRecv = Glibc.recv
#endif

/// A default implementation of `NetlinkSocket`.
public class DefaultNetlinkSocket: NetlinkSocket {
    private let sockfd: Int32

    /// The netlink port identifier assigned to this socket.
    public let pid: UInt32

    /// Creates a new instance.
    public init() throws {
        let socketFD = osSocket(Int32(AddressFamily.AF_NETLINK), SocketType.SOCK_RAW, NetlinkProtocol.NETLINK_ROUTE)
        guard socketFD >= 0 else {
            throw NetlinkSocketError.socketFailure(rc: errno)
        }

        do {
            let addr = SockaddrNetlink(family: AddressFamily.AF_NETLINK)
            var buffer = [UInt8](repeating: 0, count: SockaddrNetlink.size)
            _ = try addr.appendBuffer(&buffer, offset: 0)
            guard let ptr = buffer.bind(as: sockaddr.self, size: buffer.count) else {
                throw NetlinkSocketError.bindFailure(rc: 0)
            }
            guard osBind(socketFD, ptr, socklen_t(buffer.count)) >= 0 else {
                throw NetlinkSocketError.bindFailure(rc: errno)
            }

            var addrLength = socklen_t(buffer.count)
            guard osGetsockname(socketFD, ptr, &addrLength) >= 0 else {
                throw NetlinkSocketError.socketNameFailure(rc: errno)
            }
            let portIdentifier = try SockaddrNetlink.boundPortIdentifier(buffer: &buffer, length: addrLength)

            sockfd = socketFD
            pid = portIdentifier
        } catch {
            close(socketFD)
            throw error
        }
    }

    deinit {
        close(sockfd)
    }

    /// Sends a request to a netlink socket.
    /// Returns the number of bytes sent.
    /// - Parameters:
    ///   - buf: The buffer to send.
    ///   - len: The length of the buffer to send.
    ///   - flags: The send flags.
    public func send(buf: UnsafeRawPointer!, len: Int, flags: Int32) throws -> Int {
        let count = osSend(sockfd, buf, len, flags)
        guard count >= 0 else {
            throw NetlinkSocketError.sendFailure(rc: errno)
        }

        return count
    }

    /// Receives a response from a netlink socket.
    /// Returns the number of bytes received.
    /// - Parameters:
    ///   - buf: The buffer to receive into.
    ///   - len: The maximum number of bytes to receive.
    ///   - flags: The receive flags.
    public func recv(buf: UnsafeMutableRawPointer!, len: Int, flags: Int32) throws -> Int {
        let count = osRecv(sockfd, buf, len, flags)
        guard count >= 0 else {
            throw NetlinkSocketError.recvFailure(rc: errno)
        }

        return count
    }
}
#else
public class DefaultNetlinkSocket: NetlinkSocket {
    public var pid: UInt32 { 0 }

    public init() throws {}

    public func send(buf: UnsafeRawPointer!, len: Int, flags: Int32) throws -> Int {
        throw NetlinkSocketError.notImplemented
    }

    public func recv(buf: UnsafeMutableRawPointer!, len: Int, flags: Int32) throws -> Int {
        throw NetlinkSocketError.notImplemented
    }
}
#endif
