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
@preconcurrency import Dispatch
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
///
/// Fresh sockets remain nonblocking; managed synchronous
/// operations wait for readiness and can be interrupted by `close()`.
public final class Socket: Sendable {
    public enum TimeoutOption { case send, receive }
    public enum ShutdownOption { case read, write, readWrite }

    private enum SocketState { case created, connected, listening }
    private struct State {
        var socketState: SocketState
        var owner: OwnedDescriptor?
        let type: any SocketType
        var setup = false
        var acceptReservation: UUID?
        var closeOnDeinit: Bool
    }

    // Test rendezvous; callbacks run outside locks.
    enum WaitEvent: Sendable { case synchronousWait, acceptSourceActivated }
    fileprivate let waitObserver: (@Sendable (WaitEvent) -> Void)?
    private let state: Mutex<State>

    /// A borrowed snapshot. Saving or independently closing this integer is outside
    /// Socket's managed lifetime guarantee. The descriptor is nonblocking and
    /// close-on-exec, so blocking consumers should use `detachFileHandle()`.
    public var fileDescriptor: Int32 { state.withLock { $0.owner?.fileDescriptor ?? -1 } }

    public convenience init(type: any SocketType, closeOnDeinit: Bool = true) throws {
        let fd = sysSocket(type.domain, type.type, 0)
        guard fd >= 0 else { throw Socket.errnoToError(msg: "create socket") }
        try self.init(fd: fd, type: type, closeOnDeinit: closeOnDeinit)
    }

    /// Internal initializer for wrapping file descriptors; set `connected` for already-connected descriptors (e.g., from socketpair).
    init(
        fd: Int32,
        type: any SocketType,
        closeOnDeinit: Bool,
        connected: Bool = false,
        waitObserver: (@Sendable (WaitEvent) -> Void)? = nil
    ) throws {
        let owner = OwnedDescriptor(adopting: fd)
        do { try Self.configureSocket(fd) } catch {
            try? owner.close()
            throw error
        }
        self.waitObserver = waitObserver
        self.state = Mutex(State(socketState: connected ? .connected : .created, owner: owner, type: type, closeOnDeinit: closeOnDeinit))
    }

    deinit {
        let cleanup = state.withLock { state in state.owner?.beginClose(closePayload: state.closeOnDeinit) }
        try? cleanup?()
    }

    /// Transfer only while idle, with no setup or accept reservation.
    package func takeDescriptor() throws -> DescriptorTransfer {
        let owner = try state.withLock { state in
            guard let owner = state.owner else { throw SocketError.invalidOperationOnSocket("transferred socket") }
            guard !state.setup && state.acceptReservation == nil && owner.isIdle else {
                throw SocketError.invalidOperationOnSocket("transfer active socket")
            }
            state.owner = nil
            return owner
        }
        return DescriptorTransfer(owner: owner)
    }

    /// Ends managed ownership and returns the descriptor in blocking mode. The handle
    /// closes it on deallocation. Fails while an operation, setup or accept stream is active.
    public func detachFileHandle() throws -> FileHandle {
        let fd = try takeDescriptor().release()
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            let error = Self.errnoToError(msg: "set blocking mode")
            _ = sysClose(fd)
            throw error
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Initiate closure; use closeAndWait() to await uses and observe deferred errors.
    public func close() throws {
        let cleanup = state.withLock { $0.owner?.beginClose() }
        try cleanup?()
    }

    /// Wait for the single close attempt, including outstanding uses and registration
    /// cancellation. Task cancellation does not abandon this cleanup barrier. Like
    /// `close()`, this does nothing for a transferred socket.
    package func closeAndWait() async throws {
        guard let (owner, cleanup) = state.withLock({ state in state.owner.map { ($0, $0.beginClose()) } }) else { return }
        try cleanup()
        try await owner.closeAndWait()
    }

    private func acquire(_ operation: String, required: SocketState? = nil) throws -> (OwnedDescriptor, OwnedDescriptor.Use) {
        let (owner, use, valid) = try state.withLock { state in
            guard let owner = state.owner else { throw SocketError.closed }
            let use = try owner.acquire()
            return (owner, use, !state.setup && (required == nil || state.socketState == required))
        }
        guard valid else {
            use.end()
            throw SocketError.invalidOperationOnSocket(operation)
        }
        return (owner, use)
    }

    private func beginSetup(_ operation: String) throws -> (OwnedDescriptor, OwnedDescriptor.Use, any SocketType) {
        try state.withLock { state in
            guard let owner = state.owner else { throw SocketError.closed }
            guard state.socketState == .created && !state.setup else { throw SocketError.invalidOperationOnSocket(operation) }
            let use = try owner.acquire()
            state.setup = true
            return (owner, use, state.type)
        }
    }

    private func abandonSetup() {
        let cleanup = state.withLock { state in
            state.setup = false
            return state.owner?.beginClose()
        }
        try? cleanup?()
    }

    private func finishSetup(_ desiredState: SocketState) throws {
        try state.withLock { state in
            guard let owner = state.owner else { throw SocketError.closed }
            try owner.checkOpen()
            state.socketState = desiredState
            state.setup = false
        }
    }

    public func connect() throws {
        let (owner, use, type) = try beginSetup("connect")
        defer { use.end() }
        do {
            let deadline = try Self.deadline(fd: use.fileDescriptor, option: .send)
            #if os(Linux)
            var backoff: UInt64 = 1_000_000
            #endif
            while true {
                try Self.check(owner, deadline: deadline)
                var result: Int32 = -1
                try type.withSockAddr { address, length in result = sysConnect(use.fileDescriptor, address, length) }
                if result == 0 { break }
                let error = errno
                #if os(Linux)
                // A full AF_UNIX backlog fails a nonblocking connect with EAGAIN and leaves
                // the socket unconnected, where a blocking connect would wait for space.
                if error == EAGAIN && type.domain == AF_UNIX {
                    try pause(owner, nanoseconds: backoff, deadline: deadline)
                    backoff = min(backoff * 2, 50_000_000)
                    continue
                }
                #endif
                guard error == EINPROGRESS || error == EALREADY || error == EINTR else {
                    throw SocketError.withErrno("connect failed", errno: error)
                }
                try wait(owner, use: use, events: Int16(POLLOUT), deadline: deadline)
                try Self.check(owner, deadline: deadline)
                var status: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard sysGetsockopt(use.fileDescriptor, SOL_SOCKET, SO_ERROR, &status, &length) == 0 else {
                    throw Socket.errnoToError(msg: "connect status")
                }
                guard status == 0 else { throw SocketError.withErrno("connect failed", errno: status) }
                break
            }
            try finishSetup(.connected)
        } catch {
            abandonSetup()
            throw error
        }
    }

    public func listen() throws {
        let (owner, use, type) = try beginSetup("listen")
        defer { use.end() }
        do {
            try owner.checkOpen()
            try type.beforeBind(fd: use.fileDescriptor)
            try owner.checkOpen()
            try type.withSockAddr { address, length in
                guard sysBind(use.fileDescriptor, address, length) == 0 else { throw Socket.errnoToError(msg: "bind") }
            }
            try owner.checkOpen()
            try type.beforeListen(fd: use.fileDescriptor)
            try owner.checkOpen()
            guard sysListen(use.fileDescriptor, SOMAXCONN) == 0 else { throw Socket.errnoToError(msg: "listen") }
            try finishSetup(.listening)
        } catch {
            abandonSetup()
            throw error
        }
    }

    public func write(data: any DataProtocol) throws -> Int { try writeRegions(data) }

    private func writeRegions<D: DataProtocol>(_ data: D) throws -> Int {
        let (owner, use) = try acquire("write", required: .connected)
        defer { use.end() }
        let timeout = try Self.timeout(fd: use.fileDescriptor, option: .send)
        var deadline = Self.deadline(after: timeout)
        try Self.check(owner, deadline: deadline)
        var written = 0
        for region in data.regions {
            try region.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    try Self.check(owner, deadline: deadline)
                    // Darwin can reject SO_NOSIGPIPE on a disconnected socket; see suppressSigpipe.
                    let count = sysSend(use.fileDescriptor, base.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                    if count > 0 {
                        offset += count
                        written += count
                        deadline = Self.deadline(after: timeout)
                    } else if count == 0 {
                        throw SocketError.withErrno("send made no progress", errno: EIO)
                    } else {
                        let error = errno
                        if error == EINTR { continue }
                        guard Self.wouldBlock(error) else { throw SocketError.withErrno("send failed", errno: error) }
                        try wait(owner, use: use, events: Int16(POLLOUT), deadline: deadline)
                    }
                }
            }
        }
        return written
    }

    public func read(buffer: inout Data) throws -> Int {
        let (owner, use) = try acquire("read", required: .connected)
        defer { use.end() }
        let deadline = try Self.deadline(fd: use.fileDescriptor, option: .receive)
        try Self.check(owner, deadline: deadline)
        if buffer.isEmpty { return 0 }
        return try buffer.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw SocketError.missingBaseAddress }
            while true {
                try Self.check(owner, deadline: deadline)
                let count = sysRead(use.fileDescriptor, base, bytes.count)
                if count > 0 { return count }
                if count == 0 { throw SocketError.closed }
                let error = errno
                if error == EINTR { continue }
                guard Self.wouldBlock(error) else { throw SocketError.withErrno("read failed", errno: error) }
                try wait(owner, use: use, events: Int16(POLLIN), deadline: deadline)
            }
        }
    }

    /// Receive a file descriptor via SCM_RIGHTS control message.
    /// This is commonly used for passing file descriptors between processes via Unix domain sockets.
    /// The caller is responsible for closing the result.
    public func receiveFileDescriptor() throws -> Int32 { try receiveOwnedDescriptor().release() }

    package func receiveOwnedDescriptor() throws -> DescriptorTransfer {
        let (owner, use) = try acquire("receiveFileDescriptor", required: .connected)
        defer { use.end() }
        let deadline = try Self.deadline(fd: use.fileDescriptor, option: .receive)
        while true {
            try Self.check(owner, deadline: deadline)
            let fd = CZ_receive_fd(use.fileDescriptor)
            if fd >= 0 { return DescriptorTransfer(adopting: fd) }
            let error = errno
            if error == EINTR { continue }
            if error == ENODATA { throw SocketError.closed }
            if error == EPROTO { throw SocketError.invalidFileDescriptor }
            guard Self.wouldBlock(error) else { throw SocketError.withErrno("recvmsg failed", errno: error) }
            try wait(owner, use: use, events: Int16(POLLIN), deadline: deadline)
        }
    }

    public func shutdown(how: ShutdownOption) throws {
        let (owner, use) = try acquire("shutdown")
        defer { use.end() }
        try owner.checkOpen()
        let value: Int32
        switch how {
        case .read: value = Int32(SHUT_RD)
        case .write: value = Int32(SHUT_WR)
        case .readWrite: value = Int32(SHUT_RDWR)
        }
        guard sysShutdown(use.fileDescriptor, value) == 0 else { throw Socket.errnoToError(msg: "shutdown") }
    }

    public func setSockOpt(sockOpt: Int32 = 0, ptr: UnsafeRawPointer, stride: UInt32) throws {
        let (owner, use) = try acquire("setsockopt")
        defer { use.end() }
        try owner.checkOpen()
        guard sysSetsockopt(use.fileDescriptor, SOL_SOCKET, sockOpt, ptr, stride) == 0 else { throw Socket.errnoToError(msg: "setsockopt") }
    }

    /// Positive timeouts bound a managed call's wait for progress. Each partial send
    /// restarts the send deadline, as a kernel send timeout would.
    public func setTimeout(option: TimeoutOption, seconds: Int) throws {
        var timeout = timeval()
        timeout.tv_sec = seconds
        try withUnsafePointer(to: &timeout) {
            try setSockOpt(sockOpt: option == .send ? SO_SNDTIMEO : SO_RCVTIMEO, ptr: $0, stride: UInt32(MemoryLayout<timeval>.size))
        }
    }

    public func accept(closeOnDeinit: Bool = true) throws -> Socket {
        let (owner, use, type) = try acquireAccept(reservation: nil)
        defer { use.end() }
        let deadline = try Self.deadline(fd: use.fileDescriptor, option: .receive)
        while true {
            try Self.check(owner, deadline: deadline)
            do {
                if let child = try Self.acceptOne(use: use, type: type, closeOnDeinit: closeOnDeinit) { return child }
            } catch SocketError.withErrno(_, let error) {
                if error == EINTR { continue }
                guard Self.wouldBlock(error) else { throw SocketError.withErrno("accept failed", errno: error) }
                try wait(owner, use: use, events: Int16(POLLIN), deadline: deadline)
            }
        }
    }

    public func acceptStream(closeOnDeinit: Bool = true) throws -> AsyncThrowingStream<Socket, any Error> {
        let reservation = UUID()
        try state.withLock { state in
            guard let owner = state.owner else { throw SocketError.closed }
            try owner.checkOpen()
            guard state.socketState == .listening else { throw SocketError.invalidOperationOnSocket("accept") }
            guard state.acceptReservation == nil else { throw SocketError.acceptStreamExists }
            state.acceptReservation = reservation
        }
        let session = SocketAcceptSession(socket: self, reservation: reservation, closeOnDeinit: closeOnDeinit)
        return AsyncThrowingStream(unfolding: { try await session.next() })
    }

    fileprivate func releaseAccept(_ reservation: UUID) {
        state.withLock { state in
            if state.acceptReservation == reservation { state.acceptReservation = nil }
        }
    }

    fileprivate func acquireAccept(reservation: UUID?, onClose: (@Sendable () -> Void)? = nil) throws -> (OwnedDescriptor, OwnedDescriptor.Use, any SocketType) {
        try state.withLock { state in
            guard let owner = state.owner else { throw SocketError.closed }
            guard state.socketState == .listening else { throw SocketError.invalidOperationOnSocket("accept") }
            guard state.acceptReservation == reservation else { throw SocketError.acceptStreamExists }
            return (owner, try owner.acquire(onClose: onClose), state.type)
        }
    }

    /// Errors that end only the connection being accepted. Linux accept(2) passes
    /// pending network errors through and asks callers to retry them like EAGAIN.
    private static let perConnectionAcceptErrors: Set<Int32> = {
        var errors: Set<Int32> = [ECONNABORTED, EPROTO, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ENOPROTOOPT]
        #if os(Linux)
        // Linux reports a firewall-rejected connection as EPERM.
        errors.formUnion([ENONET, EPERM])
        #endif
        return errors
    }()

    /// Returns nil when this connection failed on its own; the listener stays usable.
    fileprivate static func acceptOne(use: OwnedDescriptor.Use, type: any SocketType, closeOnDeinit: Bool) throws -> Socket? {
        let fd: Int32
        let peerType: any SocketType
        do {
            (fd, peerType) = try type.accept(fd: use.fileDescriptor)
        } catch SocketError.withErrno(_, let error) where perConnectionAcceptErrors.contains(error) {
            return nil
        }
        return try Socket(fd: fd, type: peerType, closeOnDeinit: closeOnDeinit, connected: true)
    }

    fileprivate static func isResourceExhaustion(_ error: Int32) -> Bool {
        error == EMFILE || error == ENFILE || error == ENOBUFS || error == ENOMEM
    }

    fileprivate func setCloseOnDeinit(_ close: Bool) { state.withLock { $0.closeOnDeinit = close } }

    static func setDescriptorFlags(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw errnoToError(msg: "set nonblocking mode") }
        let descriptorFlags = fcntl(fd, F_GETFD)
        guard descriptorFlags >= 0 && fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { throw errnoToError(msg: "set close-on-exec") }
    }

    private static func configureSocket(_ fd: Int32) throws {
        try setDescriptorFlags(fd)
        try suppressSigpipe(fd)
    }

    /// Darwin rejects SO_NOSIGPIPE with EINVAL once both directions are shut down,
    /// for example when a client closes before accept. Such a socket can still hold
    /// unread data, and managed sends pass MSG_NOSIGNAL, so that is not an error.
    package static func suppressSigpipe(_ fd: Int32) throws {
        #if canImport(Darwin)
        var enabled: Int32 = 1
        guard sysSetsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 || errno == EINVAL || errno == ENOTSOCK else {
            throw errnoToError(msg: "suppress socket SIGPIPE")
        }
        #endif
    }

    fileprivate static func wouldBlock(_ error: Int32) -> Bool { error == EAGAIN || error == EWOULDBLOCK }

    /// The socket's send or receive timeout in nanoseconds, or nil when unset.
    private static func timeout(fd: Int32, option: TimeoutOption) throws -> UInt64? {
        var timeout = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        guard sysGetsockopt(fd, SOL_SOCKET, option == .send ? SO_SNDTIMEO : SO_RCVTIMEO, &timeout, &length) == 0 else {
            throw errnoToError(msg: "get socket timeout")
        }
        guard timeout.tv_sec > 0 || timeout.tv_usec > 0 else { return nil }
        let seconds = UInt64(clamping: timeout.tv_sec)
        let micros = UInt64(clamping: timeout.tv_usec)
        let (nanos, overflow1) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (fraction, overflow2) = micros.multipliedReportingOverflow(by: 1_000)
        let (duration, overflow3) = nanos.addingReportingOverflow(fraction)
        return overflow1 || overflow2 || overflow3 ? UInt64.max : duration
    }

    private static func deadline(fd: Int32, option: TimeoutOption) throws -> UInt64? {
        deadline(after: try timeout(fd: fd, option: option))
    }

    private static func deadline(after timeout: UInt64?) -> UInt64? {
        guard let timeout else { return nil }
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(timeout)
        return overflow ? UInt64.max : deadline
    }

    private static func check(_ owner: OwnedDescriptor, deadline: UInt64?) throws {
        try owner.checkOpen()
        if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { throw SocketError.withErrno("socket timeout", errno: EAGAIN) }
    }

    /// Bounds how late close() is noticed when no wake pipe is available.
    private static let wakelessPollMilliseconds: Int32 = 100

    /// Waiting must not need spare descriptors, so exhaustion falls back to bounded polls.
    private static func wakeDescriptor(for owner: OwnedDescriptor) throws -> Int32? {
        do {
            return try owner.wakeDescriptor()
        } catch SocketError.withErrno(_, let error) where isResourceExhaustion(error) {
            return nil
        }
    }

    /// Milliseconds until `end`, rounded up; -1 waits indefinitely.
    private static func pollTimeout(until end: UInt64?, wake: Int32?) -> Int32 {
        var timeout: Int32 = -1
        if let end {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = end > now ? end - now : 0
            timeout = Int32(clamping: remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1))
        }
        if wake == nil && (timeout < 0 || timeout > wakelessPollMilliseconds) { timeout = wakelessPollMilliseconds }
        return timeout
    }

    private func wait(_ owner: OwnedDescriptor, use: OwnedDescriptor.Use, events: Int16, deadline: UInt64?) throws {
        try waitForEvents(owner, socket: pollfd(fd: use.fileDescriptor, events: events, revents: 0), until: deadline, deadline: deadline)
    }

    private func pause(_ owner: OwnedDescriptor, nanoseconds: UInt64, deadline: UInt64?) throws {
        try waitForEvents(owner, socket: nil, until: min(DispatchTime.now().uptimeNanoseconds + nanoseconds, deadline ?? .max), deadline: deadline)
    }

    /// Returns once `socket` is ready, or at `end` when there is no socket to watch.
    private func waitForEvents(_ owner: OwnedDescriptor, socket: pollfd?, until end: UInt64?, deadline: UInt64?) throws {
        let wake = try Self.wakeDescriptor(for: owner)
        var entries = [socket, wake.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }].compactMap { $0 }
        var observer = waitObserver
        while true {
            try Self.check(owner, deadline: deadline)
            if socket == nil, let end, DispatchTime.now().uptimeNanoseconds >= end { return }
            // Keep this rendezvous after the last check so tests must exercise poll.
            observer?(.synchronousWait)
            observer = nil
            let result = poll(&entries, nfds_t(entries.count), Self.pollTimeout(until: end, wake: wake))
            if result < 0 {
                let error = errno
                if error == EINTR { continue }
                throw SocketError.withErrno("poll failed", errno: error)
            }
            try Self.check(owner, deadline: deadline)
            guard socket != nil, result > 0 else { continue }
            if entries[0].revents & Int16(POLLNVAL) != 0 { throw SocketError.withErrno("invalid socket in poll", errno: EBADF) }
            if entries[0].revents != 0 { return }
        }
    }

    static func errnoToError(msg: String) -> SocketError {
        let error = errno
        let description = String(validatingCString: strerror(error)) ?? "errno \(error)"
        return .withErrno("\(msg) (\(description))", errno: error)
    }
}

/// Idle streams reserve acceptance without pinning the descriptor.
private final class SocketAcceptSession: Sendable {
    private struct State {
        var active = false
        var ended = false
    }
    private let state = Mutex(State())
    private let socket: Socket
    private let reservation: UUID
    private let closeOnDeinit: Bool

    init(socket: Socket, reservation: UUID, closeOnDeinit: Bool) {
        self.socket = socket
        self.reservation = reservation
        self.closeOnDeinit = closeOnDeinit
    }

    deinit { socket.releaseAccept(reservation) }

    func next() async throws -> Socket? {
        let admitted = try state.withLock { state in
            if state.ended { return false }
            guard !state.active else { throw SocketError.invalidOperationOnSocket("overlapping accept next") }
            state.active = true
            return true
        }
        guard admitted else { return nil }
        defer { state.withLock { $0.active = false } }
        let request = SocketAcceptRequest(socket: socket, reservation: reservation, closeOnDeinit: closeOnDeinit)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { request.start($0) }
            } onCancel: {
                request.cancel()
            }
        } catch {
            state.withLock { $0.ended = true }
            socket.releaseAccept(reservation)
            if error is CancellationError { return nil }
            if let socketError = error as? SocketError, socketError == .closed { return nil }
            throw error
        }
    }
}

/// Serialize delivery against cancellation; resume only after source cancellation acknowledgement.
private final class SocketAcceptRequest: Sendable {
    private struct State {
        var starting = true
        var result: Result<Socket, any Error>?
        var continuation: CheckedContinuation<Socket, any Error>?
        var source: (any DispatchSourceRead)?
        var suspended = false
        var use: OwnedDescriptor.Use?
    }

    private let state = Mutex(State())
    private let socket: Socket
    private let reservation: UUID
    private let closeOnDeinit: Bool

    init(socket: Socket, reservation: UUID, closeOnDeinit: Bool) {
        self.socket = socket
        self.reservation = reservation
        self.closeOnDeinit = closeOnDeinit
    }

    func start(_ continuation: CheckedContinuation<Socket, any Error>) {
        state.withLock { $0.continuation = continuation }
        do {
            let (owner, use, type) = try socket.acquireAccept(reservation: reservation, onClose: { [weak self] in self?.resolve(.failure(SocketError.closed)) })
            state.withLock { $0.use = use }
            if state.withLock({ $0.result == nil }) {
                switch attempt(owner: owner, use: use, type: type) {
                case .resolved: break
                case .notReady: awaitReadiness(owner: owner, use: use, type: type)
                case .exhausted: backOff(awaitReadiness(owner: owner, use: use, type: type))
                }
            }
        } catch { resolve(.failure(error)) }
        let (source, finished) = state.withLock { state in
            state.starting = false
            return (state.source, state.result != nil)
        }
        if finished {
            if let source { cancelSource(source) } else { complete() }
        }
    }

    func cancel() { resolve(.failure(CancellationError())) }

    private enum Attempt { case resolved, notReady, exhausted }

    /// Resolves with the next deliverable connection. Connections that fail on their own
    /// are skipped rather than ending the stream.
    private func attempt(owner: OwnedDescriptor, use: OwnedDescriptor.Use, type: any SocketType) -> Attempt {
        do {
            while true {
                try owner.checkOpen()
                do {
                    if let child = try Socket.acceptOne(use: use, type: type, closeOnDeinit: true) {
                        resolve(.success(child))
                        return .resolved
                    }
                } catch SocketError.withErrno(_, let error) where Socket.wouldBlock(error) {
                    return .notReady
                } catch SocketError.withErrno(_, let error) where error == EINTR {}
            }
        } catch SocketError.withErrno(_, let error) where Socket.isResourceExhaustion(error) {
            return .exhausted
        } catch {
            resolve(.failure(error))
            return .resolved
        }
    }

    @discardableResult
    private func awaitReadiness(owner: OwnedDescriptor, use: OwnedDescriptor.Use, type: any SocketType) -> any DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: use.fileDescriptor)
        source.setEventHandler { [self] in
            guard state.withLock({ $0.result == nil }) else { return }
            if attempt(owner: owner, use: use, type: type) == .exhausted { backOff(source) }
        }
        source.setCancelHandler { [self] in complete() }
        state.withLock { $0.source = source }
        source.activate()
        socket.waitObserver?(.acceptSourceActivated)
        return source
    }

    /// Descriptor exhaustion is transient, but retrying a still-readable listener at once
    /// would spin. Pause readiness briefly instead of ending the stream.
    private func backOff(_ source: any DispatchSourceRead) {
        let suspended = state.withLock { state in
            guard state.result == nil, !state.suspended else { return false }
            state.suspended = true
            source.suspend()
            return true
        }
        guard suspended else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in resume(source) }
    }

    private func resume(_ source: any DispatchSourceRead) {
        state.withLock { state in
            guard state.suspended else { return }
            state.suspended = false
            source.resume()
        }
    }

    /// A suspended source delivers its cancel handler only after it resumes.
    private func cancelSource(_ source: any DispatchSourceRead) {
        source.cancel()
        resume(source)
    }

    private func resolve(_ result: Result<Socket, any Error>) {
        let action = state.withLock { state -> (accepted: Bool, source: (any DispatchSourceRead)?, complete: Bool) in
            guard state.result == nil else { return (false, nil, false) }
            state.result = result
            return (true, state.source, !state.starting && state.source == nil)
        }
        if !action.accepted {
            if case .success(let child) = result { try? child.close() }
            return
        }
        if let source = action.source { cancelSource(source) }
        if action.complete { complete() }
    }

    private func complete() {
        let completion = state.withLock { state -> (CheckedContinuation<Socket, any Error>, Result<Socket, any Error>, OwnedDescriptor.Use?)? in
            guard let continuation = state.continuation, let result = state.result else { return nil }
            state.continuation = nil
            state.source = nil
            let use = state.use
            state.use = nil
            return (continuation, result, use)
        }
        guard let (continuation, result, use) = completion else { return }
        use?.end()
        if case .success(let child) = result { child.setCloseOnDeinit(closeOnDeinit) }
        continuation.resume(with: result)
    }
}

public enum SocketError: Error, Equatable, CustomStringConvertible {
    case closed
    case acceptStreamExists
    case invalidOperationOnSocket(String)
    case missingBaseAddress
    case withErrno(_ msg: String, errno: Int32)
    case invalidFileDescriptor

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
        case .invalidFileDescriptor:
            return "socket: invalid file descriptor received"
        }
    }
}
