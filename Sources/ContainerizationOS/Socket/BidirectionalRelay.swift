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
import Foundation
import Logging
import Synchronization

/// Manages bidirectional data relay between two file descriptors using `DispatchSource`.
public final class BidirectionalRelay: Sendable {
    private let fd1: Int32
    private let fd2: Int32
    private let log: Logger?
    private let queue: DispatchQueue

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

    // The buffers aren't used concurrently.
    private nonisolated(unsafe) let buffer1: UnsafeMutableBufferPointer<UInt8>
    private nonisolated(unsafe) let buffer2: UnsafeMutableBufferPointer<UInt8>

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

    /// Starts the bidirectional relay to copy data from fd1 to fd2 and from fd2 to fd1.
    public func start() {
        let source1 = DispatchSource.makeReadSource(fileDescriptor: fd1, queue: queue)
        let source2 = DispatchSource.makeReadSource(fileDescriptor: fd2, queue: queue)
        state.withLock {
            $0 = ConnectionSources(source1: source1, source2: source2)
        }

        source1.setEventHandler { [self] in
            self.fdCopyHandler(
                buffer: self.buffer1,
                source: source1,
                from: self.fd1,
                to: self.fd2
            )
        }

        source2.setEventHandler { [self] in
            self.fdCopyHandler(
                buffer: self.buffer2,
                source: source2,
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
        source: DispatchSourceRead,
        from sourceFd: Int32,
        to destinationFd: Int32
    ) {
        if source.data == 0 {
            log?.debug(
                "source EOF",
                metadata: [
                    "sourceFd": "\(sourceFd)",
                    "destinationFd": "\(destinationFd)",
                ]
            )
            if !source.isCancelled {
                log?.debug(
                    "canceling DispatchSourceRead",
                    metadata: [
                        "sourceFd": "\(sourceFd)",
                        "destinationFd": "\(destinationFd)",
                    ]
                )
                source.cancel()
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
                    "size": "\(source.data)",
                ]
            )
            try Self.fileDescriptorCopy(
                buffer: buffer,
                size: source.data,
                from: sourceFd,
                to: destinationFd
            )
        } catch {
            log?.warning(
                "file descriptor copy failed",
                metadata: [
                    "error": "\(error)",
                    "sourceFd": "\(sourceFd)",
                    "destinationFd": "\(destinationFd)",
                ]
            )
            if !source.isCancelled {
                source.cancel()
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

    private static func fileDescriptorCopy(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        size: UInt,
        from sourceFd: Int32,
        to destinationFd: Int32
    ) throws {
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
            if readResult <= 0 {
                throw ContainerizationError(
                    .internalError,
                    message: "zero byte read or error in socket relay: fd \(sourceFd), result \(readResult)"
                )
            }
            readBytesRemaining -= readResult

            var writeBytesRemaining = readResult
            var writeOffset = 0
            while writeBytesRemaining > 0 {
                let writeResult = write(destinationFd, baseAddr.advanced(by: writeOffset), writeBytesRemaining)
                if writeResult <= 0 {
                    throw ContainerizationError(
                        .internalError,
                        message: "zero byte write or error in socket relay: fd \(destinationFd), result \(writeResult)"
                    )
                }
                writeBytesRemaining -= writeResult
                writeOffset += writeResult
            }
        }
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
