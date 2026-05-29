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
/// - **Serial dispatch queue** — owns all I/O state: the `Direction` objects (`d1`, `d2`)
///   and their read buffers (`buf1`, `buf2`). Every event handler, cancel handler, and
///   `stop()` call runs on this queue. No locks are needed for that state because the
///   queue is the exclusive executor. Fields in this domain are marked `nonisolated(unsafe)`.
///
/// - **Mutexes** — protect the two pieces of state that cross the queue boundary:
///   `activeDirections` (written by `start()`, which may run off-queue) and
///   `completionState` (read by `waitForCompletion()` from any async context).
public final class BidirectionalRelay: Sendable {
    private let fd1: Int32
    private let fd2: Int32
    private let log: Logger?
    private let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<Void>()

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

    private enum CompletionState {
        case pending
        case waiting(CheckedContinuation<Void, Never>)
        case completed
    }

    private enum CopyResult {
        case ok
        case blocked
        case eof
    }

    // Queue-owned state. Written by start() before activate(), so all subsequent
    // accesses from event/cancel handlers observe the initialized values without
    // additional synchronization. nonisolated(unsafe) declares that we are taking
    // responsibility for this; the serial queue is the enforcing mechanism.
    private nonisolated(unsafe) let d1 = Direction()  // fd1 → fd2
    private nonisolated(unsafe) let d2 = Direction()  // fd2 → fd1
    private nonisolated(unsafe) let buf1: UnsafeMutableBufferPointer<UInt8>
    private nonisolated(unsafe) let buf2: UnsafeMutableBufferPointer<UInt8>

    // Counts active read sources. Set to 2 in start() (possibly off-queue) and
    // decremented in cancel handlers (always on the queue). The Mutex provides the
    // cross-thread visibility guarantee for the initial write from start(). Whichever
    // cancel handler drives the count to zero calls closeBothFds() exactly once —
    // no cross-source isCancelled checks, no possibility of double-close.
    private let activeDirections: Mutex<Int>

    // May be read from any async context (waitForCompletion) and written from the
    // queue (closeBothFds), so it needs a Mutex rather than queue-only protection.
    private let completionState: Mutex<CompletionState>

    /// Creates a new bidirectional relay between two file descriptors.
    ///
    /// - Parameters:
    ///   - fd1: The first file descriptor.
    ///   - fd2: The second file descriptor.
    ///   - queue: The dispatch queue to use for I/O operations. If nil, a new queue is created.
    ///   - log: The optional logger for debugging.
    public init(
        fd1: Int32,
        fd2: Int32,
        queue: DispatchQueue? = nil,
        log: Logger? = nil
    ) {
        self.fd1 = fd1
        self.fd2 = fd2
        self.queue = queue ?? DispatchQueue(label: "com.apple.containerization.bidirectional-relay")
        self.queue.setSpecific(key: Self.queueKey, value: ())
        self.log = log
        self.activeDirections = Mutex(0)
        self.completionState = Mutex(.pending)

        let pageSize = Int(getpagesize())
        self.buf1 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: pageSize)
        self.buf2 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: pageSize)
    }

    deinit {
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
        try Self.setNonBlocking(fd1)
        try Self.setNonBlocking(fd2)

        let src1 = DispatchSource.makeReadSource(fileDescriptor: fd1, queue: queue)
        let src2 = DispatchSource.makeReadSource(fileDescriptor: fd2, queue: queue)
        d1.readSource = src1
        d2.readSource = src2
        activeDirections.withLock { $0 = 2 }

        src1.setEventHandler { [self] in handleRead(d1, from: fd1, to: fd2, buffer: buf1) }
        src2.setEventHandler { [self] in handleRead(d2, from: fd2, to: fd1, buffer: buf2) }

        src1.setCancelHandler { [self] in
            d1.writeSource?.cancel()
            d1.writeSource = nil
            directionFinished()
        }
        src2.setCancelHandler { [self] in
            d2.writeSource?.cancel()
            d2.writeSource = nil
            directionFinished()
        }

        src1.activate()
        src2.activate()
    }

    /// Stops the relay and closes both file descriptors.
    public func stop() {
        runOnQueue {
            d1.cancelRead()
            d2.cancelRead()
        }
    }

    /// Waits for the relay to complete.
    public func waitForCompletion() async {
        await withCheckedContinuation { c in
            completionState.withLock { state in
                switch state {
                case .pending:
                    state = .waiting(c)
                case .waiting:
                    fatalError("waitForCompletion called multiple times")
                case .completed:
                    c.resume()
                }
            }
        }
    }

    private func runOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func directionFinished() {
        let remaining = activeDirections.withLock { count -> Int in
            count -= 1
            return count
        }
        if remaining == 0 {
            closeBothFds()
        }
    }

    private func handleRead(
        _ dir: Direction,
        from srcFd: Int32,
        to dstFd: Int32,
        buffer: UnsafeMutableBufferPointer<UInt8>
    ) {
        do {
            switch try Self.copy(buffer: buffer, from: srcFd, to: dstFd, direction: dir) {
            case .ok:
                break

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
        let ws = DispatchSource.makeWriteSource(fileDescriptor: dstFd, queue: queue)
        dir.writeSource = ws
        ws.setEventHandler { [self] in drainPending(dir: dir, from: srcFd, to: dstFd) }
        // No cancel handler: clearing pendingData from a cancel handler would race with
        // a newly installed write source if drainPending completes and the read source
        // immediately produces another blocked write, installing a fresh write source
        // before the old cancel handler fires. pendingData is cleared explicitly by
        // drainPending on success, and freed with Direction when the relay is torn down.
        ws.activate()
    }

    private func drainPending(dir: Direction, from srcFd: Int32, to dstFd: Int32) {
        let remaining = dir.pendingData.count - dir.pendingOffset
        guard remaining > 0 else { return }

        let n = dir.pendingData.withUnsafeBufferPointer { buf in
            write(dstFd, buf.baseAddress!.advanced(by: dir.pendingOffset), remaining)
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
        } else if n == -1 && errno == EAGAIN {
            // Spurious write-ready notification; wait for the next one.
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

    /// Drains srcFd into dstFd in a loop until EAGAIN/EWOULDBLOCK or EOF.
    ///
    /// Looping until EAGAIN is required on Linux: libdispatch uses FIONREAD to decide
    /// whether to fire the read event, so when the only remaining readable condition is
    /// EOF (FIONREAD == 0), the event is suppressed. Reading in a loop here ensures we
    /// observe read() == 0 on the same handler invocation that drained the last bytes.
    private static func copy(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        from srcFd: Int32,
        to dstFd: Int32,
        direction: Direction
    ) throws -> CopyResult {
        guard let base = buffer.baseAddress else {
            throw ContainerizationError(.invalidState, message: "buffer has no base address")
        }

        readLoop: while true {
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
                let nw = write(dstFd, base.advanced(by: offset), nr - offset)
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

    private func closeBothFds() {
        log?.debug("closing fds", metadata: ["fd1": "\(fd1)", "fd2": "\(fd2)"])
        close(fd1)
        close(fd2)
        completionState.withLock { state in
            if case .waiting(let c) = state { c.resume() }
            state = .completed
        }
    }
}
