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

import Foundation
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#else
#error("Socket not supported on this platform.")
#endif

#if !os(Windows)
let sysFchmod = fchmod
let sysRead = read
let sysUnlink = unlink
let sysSend = send
let sysClose = close
let sysShutdown = shutdown
let sysBind = bind
let sysSocket = socket
let sysSetsockopt = setsockopt
let sysGetsockopt = getsockopt
let sysListen = listen
let sysAccept = accept
let sysConnect = connect
let sysIoctl: @convention(c) (CInt, CUnsignedLong, UnsafeMutableRawPointer) -> CInt = ioctl
#endif

/// Thread-safe socket wrapper.
public final class Socket: Sendable {
    public enum TimeoutOption {
        case send
        case receive
    }

    public enum ShutdownOption {
        case read
        case write
        case readWrite
    }

    private enum SocketState {
        case created
        case connected
        case listening
    }

    private struct State {
        let socketState: SocketState
        let handle: FileHandle?
        let type: SocketType
        let acceptSource: DispatchSourceRead?
    }

    private let _closeOnDeinit: Bool
    private let _queue: DispatchQueue

    private let state: Mutex<State>

    public var fileDescriptor: Int32 {
        guard let handle = state.withLock({ $0.handle }) else {
            return -1
        }
        return handle.fileDescriptor
    }

    public convenience init(type: SocketType, closeOnDeinit: Bool = true) throws {
        let sockFD = sysSocket(type.domain, type.type, 0)
        if sockFD < 0 {
            throw SocketError.withErrno("failed to create socket: \(sockFD)", errno: errno)
        }
        self.init(fd: sockFD, type: type, closeOnDeinit: closeOnDeinit)
    }

    init(fd: Int32, type: SocketType, closeOnDeinit: Bool) {
        _queue = DispatchQueue(label: "com.apple.containerization.socket")
        _closeOnDeinit = closeOnDeinit
        let state = State(
            socketState: .created,
            handle: FileHandle(fileDescriptor: fd, closeOnDealloc: false),
            type: type,
            acceptSource: nil
        )
        self.state = Mutex(state)
    }

    deinit {
        if _closeOnDeinit {
            try? close()
        }
    }
}

extension Socket {
    static func errnoToError(msg: String) -> SocketError {
        SocketError.withErrno("\(msg) (\(_errnoString(errno)))", errno: errno)
    }

    public func connect() throws {
        guard let handle = state.withLock({ $0.handle }) else {
            throw SocketError.closed
        }

        guard state.withLock({ $0.socketState }) == .created else {
            throw SocketError.invalidOperationOnSocket("connect")
        }

        var res: Int32 = 0
        try state.withLock {
            try $0.type.withSockAddr { (ptr, length) in
                res = Syscall.retrying {
                    sysConnect(handle.fileDescriptor, ptr, length)
                }
            }
        }
        if res == -1 {
            throw Socket.errnoToError(msg: "could not connect to socket \(state.withLock { $0.type })")
        }
        state.withLock {
            $0 = State(
                socketState: .connected,
                handle: handle,
                type: $0.type,
                acceptSource: $0.acceptSource
            )
        }
    }

    public func listen() throws {
        guard let handle = state.withLock({ $0.handle }) else {
            throw SocketError.closed
        }
        guard state.withLock({ $0.socketState }) == .created else {
            throw SocketError.invalidOperationOnSocket("listen")
        }

        try state.withLock { try $0.type.beforeBind(fd: handle.fileDescriptor) }

        var rc: Int32 = 0
        try state.withLock {
            try $0.type.withSockAddr { (ptr, length) in
                rc = sysBind(handle.fileDescriptor, ptr, length)
            }
        }
        if rc < 0 {
            throw Socket.errnoToError(msg: "could not bind to \(state.withLock { $0.type })")
        }

        try state.withLock { try $0.type.beforeListen(fd: handle.fileDescriptor) }
        if sysListen(handle.fileDescriptor, SOMAXCONN) < 0 {
            throw Socket.errnoToError(msg: "listen failed on \(state.withLock { $0.type })")
        }
        state.withLock {
            $0 = State(
                socketState: .listening,
                handle: handle,
                type: $0.type,
                acceptSource: $0.acceptSource
            )
        }
    }

    public func close() throws {
        // Already closed.
        guard let handle = state.withLock({ $0.handle }) else {
            return
        }
        if let acceptSource = state.withLock({ $0.acceptSource }) {
            acceptSource.cancel()
        }
        try handle.close()
        state.withLock {
            $0 = State(
                socketState: $0.socketState,
                handle: nil,
                type: $0.type,
                acceptSource: nil
            )
        }
    }

    public func write(data: any DataProtocol) throws -> Int {
        guard state.withLock({ $0.socketState }) == .connected else {
            throw SocketError.invalidOperationOnSocket("write")
        }

        guard let handle = state.withLock({ $0.handle }) else {
            throw SocketError.closed
        }

        if data.isEmpty {
            return 0
        }

        try handle.write(contentsOf: data)
        return data.count
    }

    public func acceptStream(closeOnDeinit: Bool = true) throws -> AsyncThrowingStream<Socket, Swift.Error> {
        guard state.withLock({ $0.socketState }) == .listening else {
            throw SocketError.invalidOperationOnSocket("accept")
        }

        guard let handle = state.withLock({ $0.handle }) else {
            throw SocketError.closed
        }

        guard state.withLock({ $0.acceptSource }) == nil else {
            throw SocketError.acceptStreamExists
        }

        let source = state.withLock {
            let source = DispatchSource.makeReadSource(
                fileDescriptor: handle.fileDescriptor,
                queue: _queue
            )
            $0 = State(
                socketState: $0.socketState,
                handle: handle,
                type: $0.type,
                acceptSource: source
            )
            return source
        }

        return AsyncThrowingStream { cont in
            source.setCancelHandler {
                cont.finish()
            }
            source.setEventHandler(handler: {
                if source.data == 0 {
                    source.cancel()
                    return
                }

                do {
                    let connection = try self.accept(closeOnDeinit: closeOnDeinit)
                    cont.yield(connection)
                } catch SocketError.closed {
                    source.cancel()
                } catch {
                    cont.yield(with: .failure(error))
                    source.cancel()
                }
            })
            source.activate()
        }
    }

    public func accept(closeOnDeinit: Bool = true) throws -> Socket {
        guard state.withLock({ $0.socketState }) == .listening else {
            throw SocketError.invalidOperationOnSocket("accept")
        }

        guard let handle = state.withLock({ $0.handle }) else {
            throw SocketError.closed
        }

        let (clientFD, socketType) = try state.withLock { try $0.type.accept(fd: handle.fileDescriptor) }
        return Socket(
            fd: clientFD,
            type: socketType,
            closeOnDeinit: closeOnDeinit
        )
    }

    public func read(buffer: inout Data) throws -> Int {
        guard state.withLock({ $0.socketState }) == .connected else {
            throw SocketError.invalidOperationOnSocket("read")
        }

        guard let handle = state.withLock({ $0.handle }) else {
            throw SocketError.closed
        }

        var bytesRead = 0
        let bufferSize = buffer.count
        try buffer.withUnsafeMutableBytes { pointer in
            guard let baseAddress = pointer.baseAddress else {
                throw SocketError.missingBaseAddress
            }

            bytesRead = Syscall.retrying {
                sysRead(handle.fileDescriptor, baseAddress, bufferSize)
            }
            if bytesRead < 0 {
                throw Socket.errnoToError(msg: "Error reading from connection")
            } else if bytesRead == 0 {
                throw SocketError.closed
            }
        }
        return bytesRead
    }

    public func shutdown(how: ShutdownOption) throws {
        guard let handle = state.withLock({ $0.handle }) else {
            throw SocketError.closed
        }

        var howOpt: Int32 = 0
        switch how {
        case .read:
            howOpt = Int32(SHUT_RD)
        case .write:
            howOpt = Int32(SHUT_WR)
        case .readWrite:
            howOpt = Int32(SHUT_RDWR)
        }

        if sysShutdown(handle.fileDescriptor, howOpt) < 0 {
            throw Socket.errnoToError(msg: "shutdown failed")
        }
    }

    public func setSockOpt(sockOpt: Int32 = 0, ptr: UnsafeRawPointer, stride: UInt32) throws {
        guard let handle = state.withLock({ $0.handle }) else {
            throw SocketError.closed
        }
        if setsockopt(handle.fileDescriptor, SOL_SOCKET, sockOpt, ptr, stride) < 0 {
            throw Socket.errnoToError(msg: "failed to set sockopt")
        }
    }

    public func setTimeout(option: TimeoutOption, seconds: Int) throws {
        guard let handle = state.withLock({ $0.handle }) else {
            throw SocketError.closed
        }

        var sockOpt: Int32 = 0
        switch option {
        case .receive:
            sockOpt = SO_RCVTIMEO
        case .send:
            sockOpt = SO_SNDTIMEO
        }

        var timer = timeval()
        timer.tv_sec = seconds
        timer.tv_usec = 0

        if setsockopt(
            handle.fileDescriptor,
            SOL_SOCKET,
            sockOpt,
            &timer,
            socklen_t(MemoryLayout<timeval>.size)
        ) < 0 {
            throw Socket.errnoToError(msg: "failed to set read timeout")
        }
    }

    static func _errnoString(_ err: Int32?) -> String {
        String(validatingCString: strerror(errno)) ?? "error: \(errno)"
    }
}

public enum SocketError: Error, Equatable, CustomStringConvertible {
    case closed
    case acceptStreamExists
    case invalidOperationOnSocket(String)
    case missingBaseAddress
    case withErrno(_ msg: String, errno: Int32)

    public var description: String {
        switch self {
        case .closed:
            return "socket: closed"
        case .acceptStreamExists:
            return "accept stream already exists"
        case .invalidOperationOnSocket(let operation):
            return "socket: invalid operation on socket '\(operation)'"
        case .missingBaseAddress:
            return "socket: missing base address"
        case .withErrno(let msg, _):
            return "socket: error \(msg)"
        }
    }
}
