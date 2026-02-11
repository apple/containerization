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

import CShim

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#else
#error("VsockType not supported on this platform.")
#endif

/// Vsock variant of `SocketType`.
public struct VsockType: SocketType, Sendable {
    public var domain: Int32 { AF_VSOCK }
    public var type: Int32 { _SOCK_STREAM }
    public var description: String {
        "\(cid):\(port)"
    }

    public static let anyCID: UInt32 = UInt32(bitPattern: -1)
    public static let hypervisorCID: UInt32 = 0x0
    // Supported on Linux 5.6+; otherwise, will need to use getLocalCID().
    public static let localCID: UInt32 = 0x1
    public static let hostCID: UInt32 = 0x2

    // socketFD is unused on Linux.
    public static func getLocalCID(socketFD: Int32) throws -> UInt32 {
        let request = VsockLocalCIDIoctl
        #if os(Linux)
        let fd = open("/dev/vsock", O_RDONLY | O_CLOEXEC)
        if fd == -1 {
            throw Socket.errnoToError(msg: "failed to open /dev/vsock")
        }
        defer { close(fd) }
        #else
        let fd = socketFD
        #endif
        var cid: UInt32 = 0
        guard sysIoctl(fd, numericCast(request), &cid) != -1 else {
            throw Socket.errnoToError(msg: "failed to get local cid")
        }
        return cid
    }

    public let port: UInt32
    public let cid: UInt32

    private let _addr: sockaddr_vm

    public init(port: UInt32, cid: UInt32) {
        self.cid = cid
        self.port = port
        var sockaddr = sockaddr_vm()
        sockaddr.svm_family = sa_family_t(AF_VSOCK)
        sockaddr.svm_cid = cid
        sockaddr.svm_port = port
        self._addr = sockaddr
    }

    private init(sockaddr: sockaddr_vm) {
        self._addr = sockaddr
        self.cid = sockaddr.svm_cid
        self.port = sockaddr.svm_port
    }

    public func accept(fd: Int32) throws -> (Int32, SocketType) {
        var clientFD: Int32 = -1
        var addr = sockaddr_vm()

        while clientFD < 0 {
            var size = socklen_t(MemoryLayout<sockaddr_vm>.stride)
            clientFD = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    sysAccept(fd, pointer, &size)
                }
            }
            if clientFD < 0 && errno != EINTR {
                throw Socket.errnoToError(msg: "accept failed")
            }
        }
        return (clientFD, VsockType(sockaddr: addr))
    }

    public func withSockAddr(_ closure: (UnsafePointer<sockaddr>, UInt32) throws -> Void) throws {
        var addr = self._addr
        try withUnsafePointer(to: &addr) {
            let addrBytes = UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self)
            try closure(addrBytes, UInt32(MemoryLayout<sockaddr_vm>.stride))
        }
    }
}
