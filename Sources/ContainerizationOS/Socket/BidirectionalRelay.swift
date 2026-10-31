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

import ContainerizationError
import Dispatch
import Logging
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Manages bidirectional data relay between two file descriptors using `DispatchSource`.
///
/// Uses non-blocking I/O with backpressure: when a destination fd's buffer is full,
/// the relay suspends reading from the source and installs a `DispatchSourceWrite`
/// to resume once the destination is writable again. This prevents blocking the
/// dispatch queue and avoids head-of-line blocking across connections.
///
/// ## Concurrency model
///
/// The class has two distinct synchronization domains:
///
/// - **Serial dispatch queue** — owns all I/O state: the `Direction` objects (`d1`, `d2`),
///   their read buffers (`buf1`, `buf2`), the lifecycle, and the active source count.
///   Every event handler, cancel handler, and lifecycle transition runs on this queue.
///   No locks are needed for that state because the queue is the exclusive executor.
///   Fields in this domain are marked `nonisolated(unsafe)`.
///
/// - **Mutex and atomic** — protect the state that crosses the queue boundary:
///   `completionState` (read by `waitForCompletion()` from any async context) and
///   `stopRequested` (set before `stop()` enters the queue to interrupt a busy copy loop).
///
/// Each Dispatch source pins both descriptors until cancellation finishes.
public final class BidirectionalRelay: Sendable {
    private let owner1: OwnedDescriptor
    private let owner2: OwnedDescriptor
    private let fd1: Int32
    private let fd2: Int32
    private let log: Logger?
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()

    /// Owns one direction of the relay: its read source, optional write source, and
    /// any data buffered due to backpressure.
    ///
    /// All methods must be called only from the relay's serial dispatch queue.
    private final class Direction {
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var pendingData: [UInt8] = []
        var pendingOffset: Int = 0
        private var readSuspended = false

        func suspendRead() {
            guard let src = readSource, !src.isCancelled, !readSuspended else { return }
            readSuspended = true
            src.suspend()
        }

        func resumeRead() {
            guard let src = readSource, !src.isCancelled, readSuspended else { return }
            readSuspended = false
            src.resume()
        }

        /// Resumes the read source before cancelling it if it is suspended.
        /// GCD does not deliver a cancel handler for a suspended source until it is resumed.
        func cancelRead() {
            guard let src = readSource, !src.isCancelled else { return }
            if readSuspended {
                readSuspended = false
                src.resume()
            }
            src.cancel()
        }
    }

    private struct CompletionState {
        var completed = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private enum Lifecycle { case idle, running, stopping, completed }
    private nonisolated(unsafe) var lifecycle = Lifecycle.idle
    // Counts active read and write sources, including replaced write sources whose
    // cancel handlers have not run. Updated only on the queue. Whichever cancel
    // handler drives the count to zero calls finish() exactly once.
    private nonisolated(unsafe) var activeSources = 0

    private enum CopyResult {
        case ok
        case blocked
        case eof
        case stopped
    }

    // Queue-owned state. Written by start() before activate(), so all subsequent
    // accesses from event/cancel handlers observe the initialized values without
    // additional synchronization. nonisolated(unsafe) declares that we are taking
    // responsibility for this; the serial queue is the enforcing mechanism.
    private nonisolated(unsafe) let d1 = Direction()  // fd1 → fd2
    private nonisolated(unsafe) let d2 = Direction()  // fd2 → fd1
    private nonisolated(unsafe) let buf1: UnsafeMutableBufferPointer<UInt8>
    private nonisolated(unsafe) let buf2: UnsafeMutableBufferPointer<UInt8>
    // May be read from any async context (waitForCompletion) and written from the
    // queue (finish), so it needs a Mutex rather than queue-only protection.
    private let completionState = Mutex(CompletionState())
    private let stopRequested = Atomic(false)

    /// Creates a new bidirectional relay between two file descriptors.
    ///
    /// Takes ownership of both descriptors unless it throws for invalid or equal descriptors.
    /// A started relay keeps itself alive until both directions finish or `stop()`. Any
    /// supplied queue must be serial.
    ///
    /// - Parameters:
    ///   - fd1: The first file descriptor.
    ///   - fd2: The second file descriptor.
    ///   - queue: The dispatch queue to use for I/O operations. If nil, a new queue is created.
    ///   - log: The optional logger for debugging.
    public convenience init(
        fd1: Int32,
        fd2: Int32,
        queue: DispatchQueue? = nil,
        log: Logger? = nil
    ) throws {
        guard fd1 >= 0, fd2 >= 0, fd1 != fd2 else {
            throw ContainerizationError(.invalidArgument, message: "relay needs two distinct valid descriptors, got \(fd1) and \(fd2)")
        }
        self.init(
            descriptor1: DescriptorTransfer(adopting: fd1),
            descriptor2: DescriptorTransfer(adopting: fd2),
            queue: queue,
            log: log
        )
    }

    /// Consumes exclusive control of both endpoints; start makes them nonblocking.
    package init(
        descriptor1: consuming DescriptorTransfer,
        descriptor2: consuming DescriptorTransfer,
        queue: DispatchQueue? = nil,
        log: Logger? = nil
    ) {
        self.owner1 = descriptor1.takeOwner()
        self.owner2 = descriptor2.takeOwner()
        self.fd1 = owner1.fileDescriptor
        self.fd2 = owner2.fileDescriptor
        self.queue = queue ?? DispatchQueue(label: "com.apple.containerization.bidirectional-relay")
        self.queue.setSpecific(key: queueKey, value: ())
        self.log = log

        let pageSize = Int(getpagesize())
        self.buf1 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: pageSize)
        self.buf2 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: pageSize)
    }

    deinit {
        queue.setSpecific(key: queueKey, value: nil)
        // Handlers retain the relay until their sources finish cancelling, so this runs
        // only before start or after completion.
        if lifecycle == .idle { closeOwners() }
        buf1.deallocate()
        buf2.deallocate()
    }

    private static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1 else {
            throw ContainerizationError(
                .internalError,
                message: "fcntl F_GETFL failed on fd \(fd): errno \(errno)"
            )
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw ContainerizationError(
                .internalError,
                message: "fcntl F_SETFL O_NONBLOCK failed on fd \(fd): errno \(errno)"
            )
        }
    }

    /// Starts the bidirectional relay to copy data between fd1 and fd2.
    public func start() throws {
        try runOnQueue {
            guard lifecycle == .idle, !stopRequested.load(ordering: .relaxed) else {
                throw ContainerizationError(.invalidState, message: "relay already started or stopped")
            }
            do {
                try Self.setNonBlocking(fd1)
                try Self.setNonBlocking(fd2)
                try Socket.suppressSigpipe(fd1)
                try Socket.suppressSigpipe(fd2)
            } catch {
                stopOnQueue()
                throw error
            }
            lifecycle = .running
            installReadSource(d1, from: fd1, to: fd2, buffer: buf1)
            installReadSource(d2, from: fd2, to: fd1, buffer: buf2)
        }
    }

    private func installReadSource(
        _ dir: Direction, from sourceFD: Int32, to destinationFD: Int32,
        buffer: UnsafeMutableBufferPointer<UInt8>
    ) {
        let (use1, use2) = acquireUses()
        let source = DispatchSource.makeReadSource(fileDescriptor: sourceFD, queue: queue)
        dir.readSource = source
        activeSources += 1
        // Handlers keep a started relay alive; Dispatch releases them after cancellation.
        source.setEventHandler { [self] in
            guard lifecycle == .running else { return }
            handleRead(dir, from: sourceFD, to: destinationFD, buffer: buffer)
        }
        source.setCancelHandler { [self] in
            use1.end()
            use2.end()
            dir.readSource = nil
            dir.writeSource?.cancel()
            dir.writeSource = nil
            sourceFinished()
        }
        source.activate()
    }

    /// Stops the relay and closes both file descriptors.
    /// Descriptor release waits for every source cancellation,
    /// including write sources that were replaced while relieving backpressure.
    public func stop() {
        // Interrupt a busy copy loop before waiting to enter its queue.
        stopRequested.store(true, ordering: .relaxed)
        runOnQueue { stopOnQueue() }
    }

    /// The owners close only after every source finishes, so acquiring cannot fail.
    private func acquireUses() -> (OwnedDescriptor.Use, OwnedDescriptor.Use) {
        guard let use1 = try? owner1.acquire(), let use2 = try? owner2.acquire() else {
            preconditionFailure("relay descriptors closed while a source was active")
        }
        return (use1, use2)
    }

    private func stopOnQueue() {
        guard lifecycle != .completed else { return }
        if lifecycle == .idle {
            finish()
            return
        }
        lifecycle = .stopping
        d1.cancelRead()
        d2.cancelRead()
        d1.writeSource?.cancel()
        d2.writeSource?.cancel()
        if activeSources == 0 { finish() }
    }

    /// Waits for the relay to complete.
    /// Returns after every source has stopped and both close attempts have finished.
    public func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            let completed = completionState.withLock { state in
                if state.completed { return true }
                state.waiters.append(continuation)
                return false
            }
            if completed { continuation.resume() }
        }
    }

    private func runOnQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    private func sourceFinished() {
        activeSources -= 1
        if activeSources == 0 { finish() }
    }

    private func handleRead(
        _ dir: Direction,
        from srcFd: Int32,
        to dstFd: Int32,
        buffer: UnsafeMutableBufferPointer<UInt8>
    ) {
        do {
            switch try Self.copy(buffer: buffer, from: srcFd, to: dstFd, direction: dir, shouldStop: { stopRequested.load(ordering: .relaxed) }) {
            case .ok:
                break

            case .stopped:
                stopOnQueue()

            case .eof:
                log?.debug(
                    "source EOF",
                    metadata: ["sourceFd": "\(srcFd)", "destinationFd": "\(dstFd)"]
                )
                dir.cancelRead()
                if shutdown(dstFd, Int32(SHUT_WR)) != 0 {
                    log?.debug(
                        "shutdown(SHUT_WR) failed",
                        metadata: ["fd": "\(dstFd)", "errno": "\(errno)"]
                    )
                }

            case .blocked:
                log?.debug(
                    "write blocked, applying backpressure",
                    metadata: [
                        "sourceFd": "\(srcFd)",
                        "destinationFd": "\(dstFd)",
                        "pendingBytes": "\(dir.pendingData.count)",
                    ]
                )
                dir.suspendRead()
                installWriteSource(for: dir, from: srcFd, to: dstFd)
            }
        } catch {
            log?.warning(
                "I/O error",
                metadata: [
                    "sourceFd": "\(srcFd)",
                    "destinationFd": "\(dstFd)",
                    "error": "\(error)",
                ]
            )
            dir.cancelRead()
            if shutdown(dstFd, Int32(SHUT_RDWR)) != 0 {
                log?.warning(
                    "shutdown(SHUT_RDWR) failed",
                    metadata: ["fd": "\(dstFd)", "errno": "\(errno)"]
                )
            }
        }
    }

    private func installWriteSource(for dir: Direction, from srcFd: Int32, to dstFd: Int32) {
        let (use1, use2) = acquireUses()
        let source = DispatchSource.makeWriteSource(fileDescriptor: dstFd, queue: queue)
        dir.writeSource = source
        activeSources += 1
        source.setEventHandler { [self] in
            guard lifecycle == .running else { return }
            drainPending(dir: dir, from: srcFd, to: dstFd)
        }
        source.setCancelHandler { [self] in
            use1.end()
            use2.end()
            // Clearing pendingData or writeSource here would race with a newly installed
            // write source if drainPending completes and the read source immediately
            // produces another blocked write, installing a fresh write source before
            // the old cancel handler fires. pendingData is cleared explicitly by
            // drainPending on success, and freed with Direction when the relay is torn down.
            sourceFinished()
        }
        source.activate()
    }

    private func drainPending(dir: Direction, from srcFd: Int32, to dstFd: Int32) {
        let remaining = dir.pendingData.count - dir.pendingOffset
        guard remaining > 0 else { return }

        let n = dir.pendingData.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            return Self.sendBytes(dstFd, base.advanced(by: dir.pendingOffset), remaining)
        }

        if n > 0 {
            dir.pendingOffset += n
            if dir.pendingOffset >= dir.pendingData.count {
                dir.writeSource?.cancel()
                dir.writeSource = nil
                dir.pendingData = []
                dir.pendingOffset = 0
                log?.debug(
                    "backpressure relieved, resuming reads",
                    metadata: ["sourceFd": "\(srcFd)", "destinationFd": "\(dstFd)"]
                )
                dir.resumeRead()
            }
        } else if n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            // Spurious write-ready notification or interrupted write; wait for the next one.
        } else {
            log?.warning(
                "write error during pending drain",
                metadata: ["destinationFd": "\(dstFd)", "errno": "\(errno)"]
            )
            dir.writeSource?.cancel()
            dir.writeSource = nil
            dir.cancelRead()
            if shutdown(dstFd, Int32(SHUT_RDWR)) != 0 {
                log?.warning(
                    "shutdown(SHUT_RDWR) failed after drain error",
                    metadata: ["fd": "\(dstFd)", "errno": "\(errno)"]
                )
            }
        }
    }

    /// Drains srcFd into dstFd in a loop until EAGAIN/EWOULDBLOCK, EOF, or stop.
    ///
    /// Looping until EAGAIN is required on Linux: libdispatch uses FIONREAD to decide
    /// whether to fire the read event, so when the only remaining readable condition is
    /// EOF (FIONREAD == 0), the event is suppressed. Reading in a loop here ensures we
    /// observe read() == 0 on the same handler invocation that drained the last bytes.
    private static func copy(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        from srcFd: Int32,
        to dstFd: Int32,
        direction: Direction,
        shouldStop: () -> Bool
    ) throws -> CopyResult {
        guard let base = buffer.baseAddress else {
            throw ContainerizationError(.invalidState, message: "buffer has no base address")
        }

        readLoop: while true {
            if shouldStop() { return .stopped }
            let nr = read(srcFd, base, buffer.count)
            if nr == 0 { return .eof }
            if nr < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return .ok }
                if errno == EINTR { continue readLoop }
                throw ContainerizationError(
                    .internalError,
                    message: "read failed: fd \(srcFd), errno \(errno)"
                )
            }

            var offset = 0
            while offset < nr {
                if shouldStop() { return .stopped }
                let nw = sendBytes(dstFd, base.advanced(by: offset), nr - offset)
                if nw > 0 {
                    offset += nw
                } else if nw < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        direction.pendingData = Array(
                            UnsafeBufferPointer(start: base.advanced(by: offset), count: nr - offset)
                        )
                        direction.pendingOffset = 0
                        return .blocked
                    }
                    throw ContainerizationError(
                        .internalError,
                        message: "write failed: fd \(dstFd), errno \(errno)"
                    )
                } else {
                    throw ContainerizationError(
                        .internalError,
                        message: "zero-byte write on fd \(dstFd)"
                    )
                }
            }
        }
    }

    private static func sendBytes(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        // Darwin can reject SO_NOSIGPIPE on a disconnected socket; see Socket.suppressSigpipe.
        let result = send(fd, buffer, count, Int32(MSG_NOSIGNAL))
        // The public raw initializer also accepts pipes and files.
        return result == -1 && errno == ENOTSOCK ? write(fd, buffer, count) : result
    }

    private func closeOwners() {
        log?.debug("closing fds", metadata: ["fd1": "\(fd1)", "fd2": "\(fd2)"])
        do { try owner1.close() } catch { log?.debug("relay close failed: \(error)") }
        do { try owner2.close() } catch { log?.debug("relay close failed: \(error)") }
    }

    private func finish() {
        closeOwners()
        lifecycle = .completed
        let waiters = completionState.withLock { state in
            state.completed = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
