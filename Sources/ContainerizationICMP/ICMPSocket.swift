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
import Synchronization

#if canImport(Musl)
import Musl
let osClose = Musl.close
let osSocket = Musl.socket
let osSockRaw = Int32(SOCK_RAW)
#elseif canImport(Glibc)
import Glibc
let osClose = Glibc.close
let osSocket = Glibc.socket
let osSockRaw = Int32(SOCK_RAW.rawValue)
#elseif canImport(Darwin)
import Darwin
let osClose = Darwin.close
let osSocket = Darwin.socket
let osSockRaw = SOCK_RAW
#else
#error("Platform not supported.")
#endif

public final class ICMPv4Socket: Sendable {
    private let sockfd: Mutex<Int32>

    public init() throws {
        let fd = osSocket(AF_INET, osSockRaw, Int32(IPPROTO_ICMP))
        guard fd >= 0 else {
            let err = errno
            if err == EPERM {
                throw ICMPSocketError.permissionDenied
            }
            throw ICMPSocketError.openFailed(errno: err)
        }
        sockfd = .init(fd)
    }

    deinit {
        try? close()
    }

    public func close() throws {
        try sockfd.withLock { fd in
            guard osClose(fd) >= 0 else {
                throw ICMPSocketError.closeFailed(errno: errno)
            }
        }
    }

    public func send(buffer: [UInt8], to ipAddr: IPv4Address) throws -> Int {
        guard let addr = sockaddr_in(address: ipAddr) else {
            throw ICMPSocketError.invalidAddress(address: ipAddr.description)
        }
        let bufferLen = buffer.count
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeBytes { bufPtr in
            withUnsafePointer(to: addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sockfd.withLock { fd in
                        sendto(fd, bufPtr.baseAddress, bufferLen, 0, sockaddrPtr, addrLen)
                    }
                }
            }
        }

        guard count >= 0 else {
            throw ICMPSocketError.sendFailed(errno: errno)
        }

        return count
    }

    public func receive(buffer: inout [UInt8]) throws -> (Int, IPv4Address) {
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bufferLen = buffer.count
        let count = buffer.withUnsafeMutableBytes { bufPtr in
            withUnsafeMutablePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sockfd.withLock { fd in
                        recvfrom(fd, bufPtr.baseAddress, bufferLen, 0, sockaddrPtr, &addrLen)
                    }
                }
            }
        }

        guard count >= 0 else {
            throw ICMPSocketError.receiveFailed(errno: errno)
        }

        return (count, try addr.toIPv4Address())
    }
}

public final class ICMPv6Socket: Sendable {
    private let sockfd: Mutex<Int32>

    public init() throws {
        let fd = osSocket(AF_INET6, osSockRaw, Int32(IPPROTO_ICMPV6))
        guard fd >= 0 else {
            let err = errno
            if err == EPERM {
                throw ICMPSocketError.permissionDenied
            }
            throw ICMPSocketError.openFailed(errno: err)
        }

        // Set hop limit to 255 for multicast (required for Router Solicitation per RFC 4861)
        var hops: Int32 = 255
        setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_MULTICAST_HOPS, &hops, socklen_t(MemoryLayout<Int32>.size))

        sockfd = .init(fd)
    }

    deinit {
        try? close()
    }

    public func close() throws {
        try sockfd.withLock { fd in
            guard osClose(fd) >= 0 else {
                throw ICMPSocketError.closeFailed(errno: errno)
            }
        }
    }

    public func send(buffer: [UInt8], to ipAddr: IPv6Address) throws -> Int {
        let addr = try sockaddr_in6(address: ipAddr)
        let addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let bufferLen = buffer.count
        let count = buffer.withUnsafeBytes { bufPtr in
            withUnsafePointer(to: addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sockfd.withLock { fd in
                        #if os(Darwin)
                        if ipAddr.isMulticast {
                            var scopeId = try ipAddr.scopeId()
                            setsockopt(fd, Int32(IPPROTO_IPV6), osIPv6MulticastIf, &scopeId, socklen_t(MemoryLayout<UInt32>.size))
                        }
                        #endif
                        sendto(fd, bufPtr.baseAddress, bufferLen, 0, sockaddrPtr, addrLen)
                    }
                }
            }
        }

        guard count >= 0 else {
            throw ICMPSocketError.sendFailed(errno: errno)
        }

        return count
    }

    public func receive(buffer: inout [UInt8]) throws -> (Int, IPv6Address) {
        var addr = sockaddr_in6()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let bufferLen = buffer.count
        let count = buffer.withUnsafeMutableBytes { bufPtr in
            withUnsafeMutablePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sockfd.withLock { fd in
                        recvfrom(
                            fd, bufPtr.baseAddress, bufferLen, 0,
                            sockaddrPtr, &addrLen)
                    }
                }
            }
        }

        guard count >= 0 else {
            throw ICMPSocketError.receiveFailed(errno: errno)
        }

        return (count, try addr.toIPv6Address())
    }
}

struct icmp6_filter {
    var data: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0)
}

extension sockaddr_in {
    init?(address: IPv4Address) {
        self.init()
        self.sin_family = sa_family_t(AF_INET)
        self.sin_port = 0
        withUnsafeMutableBytes(of: &self.sin_addr) { ptr in
            ptr.copyBytes(from: address.bytes)
        }
    }

    func toIPv4Address() throws -> IPv4Address {
        let bytes: [UInt8] = withUnsafeBytes(of: sin_addr) { ptr in
            [UInt8](ptr)  // Using bracket notation
        }
        return try IPv4Address(bytes)
    }
}
