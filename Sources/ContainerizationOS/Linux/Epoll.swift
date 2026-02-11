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

#if canImport(Musl)
import Musl

import Foundation
import Synchronization

/// Register file descriptors to receive events via Linux's
/// epoll syscall surface.
public final class Epoll: Sendable {
    public typealias Mask = Int32
    public typealias Handler = (@Sendable (Mask) -> Void)

    private let epollFD: Int32
    private let handlers = SafeMap<Int32, Handler>()
    private let pipe = Pipe()  // to wake up a waiting epoll_wait

    public init() throws {
        let efd = epoll_create1(EPOLL_CLOEXEC)
        guard efd > 0 else {
            throw POSIXError.fromErrno()
        }
        self.epollFD = efd
        try self.add(pipe.fileHandleForReading.fileDescriptor) { _ in }
    }

    public func add(
        _ fd: Int32,
        mask: Int32 = EPOLLIN | EPOLLOUT,  // HUP is always added
        handler: @escaping Handler
    ) throws {
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw POSIXError.fromErrno()
        }

        let events = EPOLLET | UInt32(bitPattern: mask)

        var event = epoll_event()
        event.events = events
        event.data.fd = fd

        try withUnsafeMutablePointer(to: &event) { ptr in
            while true {
                if epoll_ctl(self.epollFD, EPOLL_CTL_ADD, fd, ptr) == -1 {
                    if errno == EAGAIN || errno == EINTR {
                        continue
                    }
                    throw POSIXError.fromErrno()
                }
                break
            }
        }

        self.handlers.set(fd, handler)
    }

    /// Run the main epoll loop.
    ///
    /// max events to return in a single wait
    /// timeout in ms.
    /// -1 means block forever.
    /// 0 means return immediately if no events.
    public func run(maxEvents: Int = 128, timeout: Int32 = -1) throws {
        var events: [epoll_event] = .init(
            repeating: epoll_event(),
            count: maxEvents
        )

        while true {
            let n = epoll_wait(self.epollFD, &events, Int32(events.count), timeout)
            guard n >= 0 else {
                if errno == EINTR || errno == EAGAIN {
                    continue  // go back to epoll_wait
                }
                throw POSIXError.fromErrno()
            }

            if n == 0 {
                return  // if epoll wait times out, then n will be 0
            }

            for i in 0..<Int(n) {
                let fd = events[i].data.fd
                let mask = events[i].events

                if fd == self.pipe.fileHandleForReading.fileDescriptor {
                    close(self.epollFD)
                    return  // this is a shutdown message
                }

                guard let handler = handlers.get(fd) else {
                    continue
                }
                handler(Int32(bitPattern: mask))
            }
        }
    }

    /// Remove the provided fd from the monitored collection.
    public func delete(_ fd: Int32) throws {
        var event = epoll_event()
        let result = withUnsafeMutablePointer(to: &event) { ptr in
            epoll_ctl(self.epollFD, EPOLL_CTL_DEL, fd, ptr)
        }
        if result != 0 {
            if !acceptableDeletionErrno() {
                throw POSIXError.fromErrno()
            }
        }
        self.handlers.del(fd)
    }

    // The errno's here are acceptable and can happen if the caller
    // closed the underlying fd before calling delete().
    private func acceptableDeletionErrno() -> Bool {
        errno == ENOENT || errno == EBADF || errno == EPERM
    }

    /// Shutdown the epoll handler.
    public func shutdown() throws {
        // wakes up epoll_wait and triggers a shutdown
        try self.pipe.fileHandleForWriting.close()
    }

    private final class SafeMap<Key: Hashable & Sendable, Value: Sendable>: Sendable {
        let dict = Mutex<[Key: Value]>([:])

        func set(_ key: Key, _ value: Value) {
            dict.withLock { @Sendable in
                $0[key] = value
            }
        }

        func get(_ key: Key) -> Value? {
            dict.withLock { @Sendable in
                $0[key]
            }
        }

        func del(_ key: Key) {
            dict.withLock { @Sendable in
                _ = $0.removeValue(forKey: key)
            }
        }
    }
}

extension Epoll.Mask {
    public var isHangup: Bool {
        (self & (EPOLLHUP | EPOLLERR)) != 0
    }

    public var isRhangup: Bool {
        (self & EPOLLRDHUP) != 0
    }

    public var readyToRead: Bool {
        (self & EPOLLIN) != 0
    }

    public var readyToWrite: Bool {
        (self & EPOLLOUT) != 0
    }
}

#endif  // canImport(Musl)
