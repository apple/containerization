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

        mutating func drain(logger: Logger?) {
            guard !self.closed else { return }
            guard let readFd, let writeFd else {
                self.close(logger: logger)
                return
            }
            let readFrom = OSFile(fd: readFd)
            let writeTo = OSFile(fd: writeFd)

            while true {
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

                try ProcessSupervisor.default.registerFd(writeFd, mask: .output) { mask in
                    self.io.withLock { io in
                        if mask.isHangup && !ignoreHup {
                            io.close(logger: self.logger)
                            return
                        }
                        io.drain(logger: self.logger)
                    }
                }
                io.registeredFds.append(writeFd)
                try ProcessSupervisor.default.registerFd(readFd, mask: .input) { mask in
                    self.io.withLock { io in
                        if mask.isHangup && !ignoreHup {
                            io.closing = true
                        }
                        io.drain(logger: self.logger)
                    }
                }
                io.registeredFds.append(readFd)
            } catch {
                io.close(logger: self.logger)
                throw error
            }
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
