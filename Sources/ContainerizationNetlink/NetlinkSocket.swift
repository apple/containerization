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
        case .sendFailure(let rc):
            return "could not send netlink packet, rc = \(rc)"
        case .recvFailure(let rc):
            return "could not receive netlink packet, rc = \(rc)"
        case .notImplemented:
            return "socket function not implemented for platform"
        }
    }
}

#if canImport(Musl)
import Musl
let osSocket = Musl.socket
let osBind = Musl.bind
let osSend = Musl.send
let osRecv = Musl.recv

/// A default implementation of `NetlinkSocket`.
public class DefaultNetlinkSocket: NetlinkSocket {
    private let sockfd: Int32

    /// The process identifier of the process creating this socket.
    public let pid: UInt32

    /// Creates a new instance.
    public init() throws {
        pid = UInt32(getpid())
        sockfd = osSocket(Int32(AddressFamily.AF_NETLINK), SocketType.SOCK_RAW, NetlinkProtocol.NETLINK_ROUTE)
        guard sockfd >= 0 else {
            throw NetlinkSocketError.socketFailure(rc: errno)
        }

        let addr = SockaddrNetlink(family: AddressFamily.AF_NETLINK, pid: pid)
        var buffer = [UInt8](repeating: 0, count: SockaddrNetlink.size)
        _ = try addr.appendBuffer(&buffer, offset: 0)
        guard let ptr = buffer.bind(as: sockaddr.self, size: buffer.count) else {
            throw NetlinkSocketError.bindFailure(rc: 0)
        }
        guard osBind(sockfd, ptr, UInt32(buffer.count)) >= 0 else {
            throw NetlinkSocketError.bindFailure(rc: errno)
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
