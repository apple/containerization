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
        var closed: Bool

        func drain() {
            let readFrom = OSFile(fd: from.fileDescriptor)
            let writeTo = OSFile(fd: to.fileDescriptor)

            while true {
                let r = readFrom.read(buffer)
                if r.read > 0 {
                    let view = UnsafeMutableBufferPointer(
                        start: buffer.baseAddress,
                        count: r.read
                    )

                    let w = writeTo.write(view)
                    if w.wrote != r.read {
                        return
                    }
                }

                switch r.action {
                case .eof, .again, .error(_):
                    return
                default:
                    break
                }
            }
        }

        mutating func close(logger: Logger?) {
            if self.closed {
                return
            }

            // Try and drain IO first.
            self.drain()

            // Remove the fd from our global epoll instance first.
            let readFromFd = self.from.fileDescriptor
            do {
                try ProcessSupervisor.default.poller.delete(readFromFd)
            } catch {
                logger?.error("failed to delete fd from epoll \(readFromFd): \(error)")
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
        self.io = Mutex(
            IO(
                from: readFrom,
                to: writeTo,
                buffer: buffer,
                closed: false
            ))
        self.reason = reason
        self.logger = logger
    }

    func relay(ignoreHup: Bool = false) throws {
        self.logger?.info("setting up relay for \(reason)")

        let (readFromFd, writeToFd) = self.io.withLock { io in
            (io.from.fileDescriptor, io.to.fileDescriptor)
        }

        let readFrom = OSFile(fd: readFromFd)
        let writeTo = OSFile(fd: writeToFd)

        try ProcessSupervisor.default.poller.add(readFromFd, mask: EPOLLIN) { mask in
            self.io.withLock { io in
                if io.closed {
                    return
                }

                if mask.isHangup && !mask.readyToRead {
                    self.logger?.debug("received EPOLLHUP with no EPOLLIN")
                    if !ignoreHup {
                        io.close(logger: self.logger)
                    }
                    return
                }

                // Loop so we drain fully.
                while true {
                    let r = readFrom.read(io.buffer)
                    if r.read > 0 {
                        let view = UnsafeMutableBufferPointer(
                            start: io.buffer.baseAddress,
                            count: r.read
                        )

                        let w = writeTo.write(view)
                        if w.wrote != r.read {
                            self.logger?.error("stopping relay: short write for stdio")
                            io.close(logger: self.logger)
                            return
                        }
                    }

                    switch r.action {
                    case .error(let errno):
                        self.logger?.error("failed with errno \(errno) while reading for fd \(readFromFd)")
                        fallthrough
                    case .eof:
                        self.logger?.debug("closing relay for \(readFromFd)")
                        io.close(logger: self.logger)
                        return
                    case .again:
                        if mask.isHangup && !ignoreHup {
                            self.logger?.error("received EPOLLHUP and EAGAIN exiting")
                            self.close()
                        }
                        return
                    default:
                        break
                    }
                }
            }
        }
    }

    func close() {
        self.io.withLock { io in
            self.logger?.info("closing relay for \(reason)")
            io.close(logger: self.logger)
        }
    }
}
