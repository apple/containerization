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
let _SOCK_STREAM = SOCK_STREAM
#elseif canImport(Glibc)
import Glibc
let _SOCK_STREAM = Int32(SOCK_STREAM.rawValue)
#elseif canImport(Darwin)
import Darwin
let _SOCK_STREAM = SOCK_STREAM
#else
#error("UnixType not supported on this platform.")
#endif

/// Unix domain socket variant of `SocketType`.
public struct UnixType: SocketType, Sendable, CustomStringConvertible {
    public var domain: Int32 { AF_UNIX }
    public var type: Int32 { _SOCK_STREAM }
    public var description: String {
        path
    }

    public let path: String
    public let perms: mode_t?
    private let _addr: sockaddr_un
    private let _unlinkExisting: Bool

    private init(sockaddr: sockaddr_un) {
        let pathname: String = withUnsafePointer(to: sockaddr.sun_path) { ptr in
            let charPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            return String(cString: charPtr)
        }
        self._addr = sockaddr
        self.path = pathname
        self._unlinkExisting = false
        self.perms = nil
    }

    /// Mode and unlinkExisting only used if the socket is going to be a listening socket.
    public init(
        path: String,
        perms: mode_t? = nil,
        unlinkExisting: Bool = false
    ) throws {
        self.path = path
        self.perms = perms
        self._unlinkExisting = unlinkExisting
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let socketName = path
        let nameLength = socketName.utf8.count

        #if os(macOS)
        // Funnily enough, this isn't limited by sun path on macOS even though
        // it's stated as so.
        let lengthLimit = 253
        #elseif os(Linux)
        let lengthLimit = MemoryLayout.size(ofValue: addr.sun_path)
        #endif

        guard nameLength < lengthLimit else {
            throw Error.nameTooLong(path)
        }

        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketName.withCString { strncpy(ptr, $0, nameLength) }
        }

        #if os(macOS)
        addr.sun_len = UInt8(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + socketName.utf8.count + 1)
        #endif
        self._addr = addr
    }

    public func accept(fd: Int32) throws -> (Int32, SocketType) {
        var clientFD: Int32 = -1
        var addr = sockaddr_un()

        clientFD = Syscall.retrying {
            var size = socklen_t(MemoryLayout<sockaddr_un>.stride)
            return withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    sysAccept(fd, pointer, &size)
                }
            }
        }
        if clientFD < 0 {
            throw Socket.errnoToError(msg: "accept failed")
        }

        return (clientFD, UnixType(sockaddr: addr))
    }

    public func beforeBind(fd: Int32) throws {
        #if os(Linux)
        // Only Linux supports setting the mode of a socket before binding.
        if let perms = self.perms {
            guard fchmod(fd, perms) == 0 else {
                throw Socket.errnoToError(msg: "fchmod failed")
            }
        }
        #endif

        var rc: Int32 = 0
        if self._unlinkExisting {
            rc = sysUnlink(self.path)
            if rc != 0 && errno != ENOENT {
                throw Socket.errnoToError(msg: "failed to remove old socket at \(self.path)")
            }
        }
    }

    public func beforeListen(fd: Int32) throws {
        #if os(macOS)
        if let perms = self.perms {
            guard chmod(self.path, perms) == 0 else {
                throw Socket.errnoToError(msg: "chmod failed")
            }
        }
        #endif
    }

    public func withSockAddr(_ closure: (UnsafePointer<sockaddr>, UInt32) throws -> Void) throws {
        var addr = self._addr
        try withUnsafePointer(to: &addr) {
            let addrBytes = UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self)
            try closure(addrBytes, UInt32(MemoryLayout<sockaddr_un>.stride))
        }
    }
}

extension UnixType {
    /// `UnixType` errors.
    public enum Error: Swift.Error, CustomStringConvertible {
        case nameTooLong(_: String)

        public var description: String {
            switch self {
            case .nameTooLong(let name):
                return "\(name) is too long for a Unix Domain Socket path"
            }
        }
    }
}
