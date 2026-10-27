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

#if os(Linux)

import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import Synchronization

final class IOPair: Sendable {
    private let io: Mutex<IO>
    private let logger: Logger?
    private let reason: String

    private struct IO {
        let from: IOCloser
        let to: IOCloser
        let buffer: UnsafeMutableBufferPointer<UInt8>
        var closed = false
        var closing = false
        var readFinished = false
        var bufferedBytes = 0
        var writeOffset = 0
        var readFd: Int32?
        var writeFd: Int32?
        var registeredFds: [Int32] = []
        var ignoreHup = false

        /// Bytes that were taken from the source but could not be handed to the sink yet, which
        /// `drain` must write before it reads anything else. Only a failed `detach` leaves any.
        var overflow = Data()

        mutating func refillFromOverflow() {
            let count = min(self.overflow.count, self.buffer.count)
            guard count > 0 else { return }
            _ = self.overflow.prefix(count).copyBytes(to: self.buffer)
            self.overflow.removeFirst(count)
            self.writeOffset = 0
            self.bufferedBytes = count
        }

        mutating func drain(logger: Logger?) {
            guard !self.closed else { return }
            guard let readFd, let writeFd else {
                self.close(logger: logger)
                return
            }
            let readFrom = OSFile(fd: readFd)
            let writeTo = OSFile(fd: writeFd)

            while true {
                if self.bufferedBytes == 0 && !self.overflow.isEmpty {
                    self.refillFromOverflow()
                }
                if self.bufferedBytes > 0 {
                    let view = UnsafeMutableBufferPointer(
                        start: self.buffer.baseAddress?.advanced(by: self.writeOffset),
                        count: self.bufferedBytes
                    )
                    let result = writeTo.write(view)
                    self.writeOffset += result.wrote
                    self.bufferedBytes -= result.wrote
                    switch result.action {
                    case .error(let errno):
                        logger?.error("failed with errno \(errno) while writing for fd \(writeFd)")
                        fallthrough
                    case .brokenPipe:
                        self.close(logger: logger)
                        return
                    case .again:
                        if self.closing {
                            var event = pollfd(fd: writeFd, events: 0, revents: 0)
                            while poll(&event, 1, 0) == -1 && errno == EINTR {}
                            if event.revents & Int16(POLLHUP | POLLERR) != 0 {
                                self.close(logger: logger)
                            }
                        }
                        return
                    default:
                        break
                    }
                }
                if !self.overflow.isEmpty {
                    continue
                }
                if self.readFinished {
                    self.close(logger: logger)
                    return
                }

                let result = readFrom.read(self.buffer)
                self.bufferedBytes = result.read
                self.writeOffset = 0
                switch result.action {
                case .error(let errno):
                    logger?.error("failed with errno \(errno) while reading for fd \(readFd)")
                    fallthrough
                case .eof:
                    self.readFinished = true
                case .again:
                    self.readFinished = self.closing
                default:
                    break
                }
                if self.bufferedBytes == 0 {
                    if self.readFinished {
                        self.close(logger: logger)
                    }
                    return
                }
            }
        }

        mutating func close(logger: Logger?) {
            guard !self.closed else { return }

            for fd in self.registeredFds {
                do {
                    try ProcessSupervisor.default.unregisterFd(fd)
                } catch {
                    logger?.error("failed to delete fd from epoll \(fd): \(error)")
                }
            }
            self.registeredFds.removeAll()
            if let readFd = self.readFd {
                Foundation.close(readFd)
                self.readFd = nil
            }
            if let writeFd = self.writeFd {
                Foundation.close(writeFd)
                self.writeFd = nil
            }

            do {
                try self.from.close()
            } catch {
                logger?.error("failed to close reader fd for IOPair: \(error)")
            }
            do {
                try self.to.close()
            } catch {
                logger?.error("failed to close writer fd for IOPair: \(error)")
            }
            self.buffer.deallocate()
            self.closed = true
        }
    }

    init(
        readFrom: IOCloser,
        writeTo: IOCloser,
        reason: String,
        logger: Logger? = nil
    ) {
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))
        self.io = Mutex(IO(from: readFrom, to: writeTo, buffer: buffer))
        self.reason = reason
        self.logger = logger
    }

    func relay(ignoreHup: Bool = false) throws {
        self.logger?.info("setting up relay for \(reason)")
        try self.io.withLock { io in
            do {
                // Own the active descriptors so a deferred drain survives the caller's close.
                // Distinct descriptors also allow both terminal directions to monitor the shared PTY.
                let readFd = fcntl(io.from.fileDescriptor, F_DUPFD_CLOEXEC, 0)
                guard readFd >= 0 else { throw POSIXError.fromErrno() }
                io.readFd = readFd
                let writeFd = fcntl(io.to.fileDescriptor, F_DUPFD_CLOEXEC, 0)
                guard writeFd >= 0 else { throw POSIXError.fromErrno() }
                io.writeFd = writeFd
                io.ignoreHup = ignoreHup

                try self.arm(&io)
            } catch {
                io.close(logger: self.logger)
                throw error
            }
        }
    }

    /// Register the active descriptors with the process supervisor's epoll.
    private func arm(_ io: inout IO) throws {
        guard let readFd = io.readFd, let writeFd = io.writeFd else {
            throw ContainerizationError(.invalidState, message: "relay for \(reason) has no descriptors")
        }
        try ProcessSupervisor.default.registerFd(writeFd, mask: .output) { mask in
            self.io.withLock { io in
                if mask.isHangup && !io.ignoreHup {
                    io.close(logger: self.logger)
                    return
                }
                io.drain(logger: self.logger)
            }
        }
        io.registeredFds.append(writeFd)
        try ProcessSupervisor.default.registerFd(readFd, mask: .input) { mask in
            self.io.withLock { io in
                if mask.isHangup && !io.ignoreHup {
                    io.closing = true
                }
                io.drain(logger: self.logger)
            }
        }
        io.registeredFds.append(readFd)
    }

    /// Largest amount of stdin that detaching will take out of the source.
    private static let maxDetachBytes = 16 * 1024 * 1024

    /// Stop relaying so the descriptors on the process side can be handed to a new relay, and
    /// return the bytes that were taken from the source but never reached the sink.
    ///
    /// Nothing is written to the sink. After this returns the pair owns nothing: it is
    /// unregistered from epoll, its duplicated descriptors are closed, and both ends were closed.
    /// The socket end really closes. An end wrapped in `UnownedIOCloser` is left open for whoever
    /// holds it. The caller must write the returned bytes first on the replacement relay.
    ///
    /// - Parameter readUntilEOF: Whether the source is a peer that has stopped sending and is
    ///   expected to be at end-of-stream (a socket carrying stdin). Everything it sent is read and
    ///   returned. Leave it `false` when the source is a process's output: that is never at EOF
    ///   while the process runs, and what the process has written but not been read stays in its
    ///   pipe for the next relay.
    ///   A relay that already ended (its socket went away or its source finished) has nothing to
    ///   release and nothing pending, so detaching it returns no bytes.
    ///
    /// - Throws: If `readUntilEOF` and the source did not reach EOF, failed, or sent more than
    ///   `maxDetachBytes`. Nothing is lost and the pair is left relaying exactly as before, with
    ///   what it had read queued to be written first.
    func detach(readUntilEOF: Bool) throws -> Data {
        try self.io.withLock { io in
            if io.closed {
                return Data()
            }
            guard let readFd = io.readFd, io.writeFd != nil else {
                throw ContainerizationError(.invalidState, message: "relay for \(self.reason) was never started")
            }

            // No more epoll events means no more drain, and so no more close.
            for fd in io.registeredFds {
                do {
                    try ProcessSupervisor.default.unregisterFd(fd)
                } catch {
                    self.logger?.error("failed to delete fd from epoll \(fd): \(error)")
                }
            }
            io.registeredFds.removeAll()

            // Everything read but not yet written, oldest first.
            var pending = Data()
            if io.bufferedBytes > 0, let base = io.buffer.baseAddress {
                pending.append(UnsafeBufferPointer(start: base.advanced(by: io.writeOffset), count: io.bufferedBytes))
            }
            pending.append(io.overflow)
            io.bufferedBytes = 0
            io.writeOffset = 0
            io.overflow = Data()

            if readUntilEOF {
                let reader = OSFile(fd: readFd)
                var reachedEOF = false
                var failure: Error?
                readLoop: while true {
                    let result = reader.read(io.buffer)
                    if result.read > 0, let base = io.buffer.baseAddress {
                        pending.append(UnsafeBufferPointer(start: base, count: result.read))
                    }
                    if pending.count > Self.maxDetachBytes {
                        failure = ContainerizationError(
                            .invalidState,
                            message: "\(self.reason) has more than \(Self.maxDetachBytes) bytes pending while detaching"
                        )
                        break readLoop
                    }
                    switch result.action {
                    case .success:
                        continue readLoop
                    case .eof:
                        reachedEOF = true
                        break readLoop
                    case .again, .brokenPipe:
                        break readLoop
                    case .error(let errno):
                        failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        break readLoop
                    }
                }

                if !reachedEOF {
                    // Put everything back the way it was.
                    io.overflow = pending
                    do {
                        try self.arm(&io)
                    } catch {
                        io.close(logger: self.logger)
                        throw error
                    }
                    throw failure
                        ?? ContainerizationError(
                            .invalidState,
                            message: "\(self.reason) did not reach end of stream while detaching"
                        )
                }
            }

            io.close(logger: self.logger)
            return pending
        }
    }

    func close() {
        self.io.withLock { io in
            self.logger?.info("closing relay for \(reason)")
            io.closing = true
            io.drain(logger: self.logger)
        }
    }
}

#endif
