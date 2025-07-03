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

import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import Synchronization

final class IOPair: Sendable {
    let readFrom: IOCloser
    let writeTo: IOCloser
    nonisolated(unsafe) let buffer: UnsafeMutableBufferPointer<UInt8>
    private let logger: Logger?

    private let done: Atomic<Bool>

    init(readFrom: IOCloser, writeTo: IOCloser, logger: Logger? = nil) {
        self.readFrom = readFrom
        self.writeTo = writeTo
        self.done = Atomic(false)
        self.buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))
        self.logger = logger
    }

    func relay() throws {
        let readFromFd = self.readFrom.fileDescriptor
        let writeToFd = self.writeTo.fileDescriptor

        let readFrom = OSFile(fd: readFromFd)
        let writeTo = OSFile(fd: writeToFd)

        try ProcessSupervisor.default.poller.add(readFromFd, mask: EPOLLIN) { mask in
            if mask.isHangup && !mask.readyToRead {
                self.close()
                return
            }
            // Loop so that in the case that someone wrote > buf.count down the pipe
            // we properly will drain it fully.
            while true {
                let r = readFrom.read(self.buffer)
                if r.read > 0 {
                    let view = UnsafeMutableBufferPointer(
                        start: self.buffer.baseAddress,
                        count: r.read
                    )

                    let w = writeTo.write(view)
                    if w.wrote != r.read {
                        self.logger?.error("stopping relay: short write for stdio")
                        self.close()
                        return
                    }
                }

                switch r.action {
                case .error(let errno):
                    self.logger?.error("failed with errno \(errno) while reading for fd \(readFromFd)")
                    fallthrough
                case .eof:
                    self.close()
                    self.logger?.debug("closing relay for \(readFromFd)")
                    return
                case .again:
                    // We read all we could, exit.
                    if mask.isHangup {
                        self.close()
                    }
                    return
                default:
                    break
                }
            }
        }
    }

    func close() {
        guard
            self.done.compareExchange(
                expected: false,
                desired: true,
                successOrdering: .acquiringAndReleasing,
                failureOrdering: .acquiring
            ).exchanged
        else {
            return
        }

        self.buffer.deallocate()

        let readFromFd = self.readFrom.fileDescriptor
        // Remove the fd from our global epoll instance first.
        do {
            try ProcessSupervisor.default.poller.delete(readFromFd)
        } catch {
            self.logger?.error("failed to delete fd from epoll \(readFromFd): \(error)")
        }

        do {
            try self.readFrom.close()
        } catch {
            self.logger?.error("failed to close reader fd for IOPair: \(error)")
        }

        do {
            try self.writeTo.close()
        } catch {
            self.logger?.error("failed to close writer fd for IOPair: \(error)")
        }
    }
}
