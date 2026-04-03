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
public final class BidirectionalRelay: Sendable {
    private let fd1: Int32
    private let fd2: Int32
    private let log: Logger?
    private let queue: DispatchQueue

    /// Per-direction write state, only accessed from the serial dispatch queue.
    private class DirectionState: @unchecked Sendable {
        var writeSource: DispatchSourceWrite?
        var pendingData: [UInt8] = []
        var pendingOffset: Int = 0
        var readSourceSuspended: Bool = false
    }

    // `DispatchSourceRead` is thread-safe.
    private struct ConnectionSources: @unchecked Sendable {
        let source1: DispatchSourceRead
        let source2: DispatchSourceRead
    }

    private enum CompletionState {
        case pending
        case waiting(CheckedContinuation<Void, Never>)
        case completed
    }

    private let state: Mutex<ConnectionSources?>
    private let completionState: Mutex<CompletionState>

    // The buffers and direction states aren't used concurrently (accessed only from the queue).
    private nonisolated(unsafe) let buffer1: UnsafeMutableBufferPointer<UInt8>
    private nonisolated(unsafe) let buffer2: UnsafeMutableBufferPointer<UInt8>
    private let directionState1 = DirectionState()
    private let directionState2 = DirectionState()

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
        self.log = log
        self.state = Mutex(nil)
        self.completionState = Mutex(.pending)

        let pageSize = Int(getpagesize())
        self.buffer1 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: pageSize)
        self.buffer2 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: pageSize)
    }

    deinit {
        buffer1.deallocate()
        buffer2.deallocate()
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

    /// Starts the bidirectional relay to copy data from fd1 to fd2 and from fd2 to fd1.
    public func start() throws {
        try Self.setNonBlocking(fd1)
        try Self.setNonBlocking(fd2)

        let source1 = DispatchSource.makeReadSource(fileDescriptor: fd1, queue: queue)
        let source2 = DispatchSource.makeReadSource(fileDescriptor: fd2, queue: queue)
        state.withLock {
            $0 = ConnectionSources(source1: source1, source2: source2)
        }

        source1.setEventHandler { [self] in
            self.fdCopyHandler(
                buffer: self.buffer1,
                directionState: self.directionState1,
                readSource: source1,
                from: self.fd1,
                to: self.fd2
            )
        }

        source2.setEventHandler { [self] in
            self.fdCopyHandler(
                buffer: self.buffer2,
                directionState: self.directionState2,
                readSource: source2,
                from: self.fd2,
                to: self.fd1
            )
        }

        // Only close underlying fds when both sources are at EOF.
        // Ensure that one of the cancel handlers will see both sources cancelled.
        source1.setCancelHandler { [self] in
            self.log?.debug(
                "source1 cancel received",
                metadata: ["fd1": "\(self.fd1)", "fd2": "\(self.fd2)"]
            )

            self.state.withLock { _ in
                self.directionState1.writeSource?.cancel()
                self.directionState1.writeSource = nil
                if source2.isCancelled {
                    self.closeBothFds()
                }
            }
        }

        source2.setCancelHandler { [self] in
            self.log?.debug(
                "source2 cancel received",
                metadata: ["fd1": "\(self.fd1)", "fd2": "\(self.fd2)"]
            )

            self.state.withLock { _ in
                self.directionState2.writeSource?.cancel()
                self.directionState2.writeSource = nil
                if source1.isCancelled {
                    self.closeBothFds()
                }
            }
        }

        source1.activate()
        source2.activate()
    }

    /// Stops the relay and closes both file descriptors.
    public func stop() {
        state.withLock { sources in
            // Resume any suspended read sources before cancelling.
            // GCD will not deliver cancel handlers on suspended sources.
            if directionState1.readSourceSuspended {
                sources?.source1.resume()
                directionState1.readSourceSuspended = false
            }
            if directionState2.readSourceSuspended {
                sources?.source2.resume()
                directionState2.readSourceSuspended = false
            }
            sources?.source1.cancel()
            sources?.source2.cancel()
            sources = nil
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

    private func fdCopyHandler(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        directionState: DirectionState,
        readSource: DispatchSourceRead,
        from sourceFd: Int32,
        to destinationFd: Int32
    ) {
        if readSource.data == 0 {
            log?.debug(
                "source EOF",
                metadata: [
                    "sourceFd": "\(sourceFd)",
                    "destinationFd": "\(destinationFd)",
                ]
            )
            if !readSource.isCancelled {
                log?.debug(
                    "canceling DispatchSourceRead",
                    metadata: [
                        "sourceFd": "\(sourceFd)",
                        "destinationFd": "\(destinationFd)",
                    ]
                )
                readSource.cancel()
                if shutdown(destinationFd, Int32(SHUT_WR)) != 0 {
                    log?.debug(
                        "failed to shut down writes",
                        metadata: [
                            "errno": "\(errno)",
                            "sourceFd": "\(sourceFd)",
                            "destinationFd": "\(destinationFd)",
                        ]
                    )
                }
            }
            return
        }

        do {
            log?.trace(
                "source copy",
                metadata: [
                    "sourceFd": "\(sourceFd)",
                    "destinationFd": "\(destinationFd)",
                    "size": "\(readSource.data)",
                ]
            )
            let blocked = try Self.fileDescriptorCopy(
                buffer: buffer,
                size: readSource.data,
                from: sourceFd,
                to: destinationFd,
                directionState: directionState
            )

            if blocked {
                log?.debug(
                    "write blocked, applying backpressure",
                    metadata: [
                        "sourceFd": "\(sourceFd)",
                        "destinationFd": "\(destinationFd)",
                        "pendingBytes": "\(directionState.pendingData.count - directionState.pendingOffset)",
                    ]
                )
                readSource.suspend()
                directionState.readSourceSuspended = true
                self.installWriteSource(
                    directionState: directionState,
                    readSource: readSource,
                    sourceFd: sourceFd,
                    destinationFd: destinationFd
                )
            }
        } catch {
            log?.warning(
                "file descriptor copy failed",
                metadata: [
                    "error": "\(error)",
                    "sourceFd": "\(sourceFd)",
                    "destinationFd": "\(destinationFd)",
                ]
            )
            if !readSource.isCancelled {
                readSource.cancel()
                if shutdown(destinationFd, Int32(SHUT_RDWR)) != 0 {
                    log?.warning(
                        "failed to shut down destination after I/O error",
                        metadata: [
                            "errno": "\(errno)",
                            "sourceFd": "\(sourceFd)",
                            "destinationFd": "\(destinationFd)",
                        ]
                    )
                }
            }
        }
    }

    /// Installs a `DispatchSourceWrite` to drain pending data when the destination becomes writable.
    private func installWriteSource(
        directionState: DirectionState,
        readSource: DispatchSourceRead,
        sourceFd: Int32,
        destinationFd: Int32
    ) {
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: destinationFd, queue: queue)
        directionState.writeSource = writeSource

        writeSource.setEventHandler { [self] in
            self.drainPendingWrite(
                directionState: directionState,
                readSource: readSource,
                sourceFd: sourceFd,
                destinationFd: destinationFd
            )
        }

        writeSource.setCancelHandler {
            directionState.pendingData = []
            directionState.pendingOffset = 0
        }

        writeSource.activate()
    }

    /// Attempts to write pending data. Resumes reading when all pending data is drained.
    private func drainPendingWrite(
        directionState: DirectionState,
        readSource: DispatchSourceRead,
        sourceFd: Int32,
        destinationFd: Int32
    ) {
        let remaining = directionState.pendingData.count - directionState.pendingOffset
        guard remaining > 0 else {
            return
        }

        let result = directionState.pendingData.withUnsafeBufferPointer { buf in
            guard let baseAddress = buf.baseAddress else {
                return -1
            }
            return write(destinationFd, baseAddress.advanced(by: directionState.pendingOffset), remaining)
        }

        if result > 0 {
            directionState.pendingOffset += result
            if directionState.pendingOffset >= directionState.pendingData.count {
                // All pending data written — cancel write source and resume reading.
                directionState.writeSource?.cancel()
                directionState.writeSource = nil
                directionState.pendingData = []
                directionState.pendingOffset = 0

                log?.debug(
                    "backpressure relieved, resuming reads",
                    metadata: [
                        "sourceFd": "\(sourceFd)",
                        "destinationFd": "\(destinationFd)",
                    ]
                )
                if !readSource.isCancelled {
                    directionState.readSourceSuspended = false
                    readSource.resume()
                }
            }
        } else if result == -1 && errno == EAGAIN {
            // Still not writable, wait for next write source event.
            return
        } else {
            // Write error — tear down this direction.
            log?.warning(
                "write failed during pending drain",
                metadata: [
                    "errno": "\(errno)",
                    "sourceFd": "\(sourceFd)",
                    "destinationFd": "\(destinationFd)",
                ]
            )
            directionState.writeSource?.cancel()
            directionState.writeSource = nil
            if !readSource.isCancelled {
                readSource.cancel()
                if shutdown(destinationFd, Int32(SHUT_RDWR)) != 0 {
                    log?.warning(
                        "failed to shut down destination after drain error",
                        metadata: [
                            "errno": "\(errno)",
                            "sourceFd": "\(sourceFd)",
                            "destinationFd": "\(destinationFd)",
                        ]
                    )
                }
            }
        }
    }

    /// Copies data from source to destination fd. Returns `true` if the write would block
    /// (EAGAIN), in which case remaining data is stored in `directionState.pendingData`.
    private static func fileDescriptorCopy(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        size: UInt,
        from sourceFd: Int32,
        to destinationFd: Int32,
        directionState: DirectionState
    ) throws -> Bool {
        let bufferSize = buffer.count
        var readBytesRemaining = min(Int(size), bufferSize)

        guard let baseAddr = buffer.baseAddress else {
            throw ContainerizationError(
                .invalidState,
                message: "buffer has no base address"
            )
        }

        while readBytesRemaining > 0 {
            let readResult = read(sourceFd, baseAddr, min(bufferSize, readBytesRemaining))
            if readResult == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Spurious wakeup or data not yet available — not an error.
                return false
            }
            if readResult <= 0 {
                throw ContainerizationError(
                    .internalError,
                    message: "zero byte read or error in socket relay: fd \(sourceFd), result \(readResult), errno \(errno)"
                )
            }
            readBytesRemaining -= readResult

            var writeBytesRemaining = readResult
            var writeOffset = 0
            while writeBytesRemaining > 0 {
                let writeResult = write(destinationFd, baseAddr.advanced(by: writeOffset), writeBytesRemaining)
                if writeResult == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // Destination buffer full — save remaining data for async drain.
                    let pendingStart = writeOffset
                    let pendingCount = writeBytesRemaining
                    directionState.pendingData = Array(
                        UnsafeBufferPointer(start: baseAddr.advanced(by: pendingStart), count: pendingCount)
                    )
                    directionState.pendingOffset = 0
                    return true
                }
                if writeResult <= 0 {
                    throw ContainerizationError(
                        .internalError,
                        message: "zero byte write or error in socket relay: fd \(destinationFd), result \(writeResult), errno \(errno)"
                    )
                }
                writeBytesRemaining -= writeResult
                writeOffset += writeResult
            }
        }
        return false
    }

    private func closeBothFds() {
        log?.debug(
            "close file descriptors",
            metadata: ["fd1": "\(fd1)", "fd2": "\(fd2)"]
        )
        close(fd1)
        close(fd2)
        completionState.withLock { state in
            if case .waiting(let c) = state {
                c.resume()
            }
            state = .completed
        }
    }
}
