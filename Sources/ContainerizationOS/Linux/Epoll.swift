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

#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Musl)
import Musl
private let _write = Musl.write
#elseif canImport(Glibc)
import Glibc
private let _write = Glibc.write
#endif

import CShim

// On glibc, epoll constants are EPOLL_EVENTS enum values. On musl they're
// plain UInt32. These helpers normalize them to UInt32/Int32.
private func epollMask(_ value: UInt32) -> UInt32 { value }
private func epollMask(_ value: Int32) -> UInt32 { UInt32(bitPattern: value) }
#if canImport(Glibc)
private func epollMask(_ value: EPOLL_EVENTS) -> UInt32 { value.rawValue }
private func epollFlag(_ value: EPOLL_EVENTS) -> Int32 { Int32(bitPattern: value.rawValue) }
#endif

/// A thin wrapper around the Linux epoll syscall surface.
public final class Epoll: Sendable {
    /// A set of epoll event flags.
    public struct Mask: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let input = Mask(rawValue: epollMask(EPOLLIN))
        public static let output = Mask(rawValue: epollMask(EPOLLOUT))

        public var isHangup: Bool {
            !self.isDisjoint(with: Mask(rawValue: epollMask(EPOLLHUP) | epollMask(EPOLLERR)))
        }

        public var isRemoteHangup: Bool {
            !self.isDisjoint(with: Mask(rawValue: epollMask(EPOLLRDHUP)))
        }

        public var readyToRead: Bool {
            self.contains(.input)
        }

        public var readyToWrite: Bool {
            self.contains(.output)
        }
    }

    /// An event returned by `wait()`.
    public struct Event: Sendable {
        public let fd: Int32
        public let mask: Mask
    }

    private let epollFD: Int32
    private let eventFD: Int32

    public init() throws {
        let efd = epoll_create1(Int32(EPOLL_CLOEXEC))
        guard efd >= 0 else {
            throw POSIXError.fromErrno()
        }

        let evfd = eventfd(0, Int32(EFD_CLOEXEC | EFD_NONBLOCK))
        guard evfd >= 0 else {
            let evfdErrno = POSIXError.fromErrno()
            close(efd)
            throw evfdErrno
        }

        self.epollFD = efd
        self.eventFD = evfd

        // Register the eventfd with epoll for shutdown signaling.
        var event = epoll_event()
        event.events = epollMask(EPOLLIN)
        event.data.fd = self.eventFD
        let ctlResult = withUnsafeMutablePointer(to: &event) { ptr in
            epoll_ctl(efd, EPOLL_CTL_ADD, self.eventFD, ptr)
        }
        guard ctlResult == 0 else {
            let ctlErrno = POSIXError.fromErrno()
            close(evfd)
            close(efd)
            throw ctlErrno
        }
    }

    deinit {
        close(epollFD)
        close(eventFD)
    }

    /// Register a file descriptor for edge-triggered monitoring.
    public func add(_ fd: Int32, mask: Mask) throws {
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw POSIXError.fromErrno()
        }

        let events = epollMask(EPOLLET) | mask.rawValue

        var event = epoll_event()
        event.events = events
        event.data.fd = fd

        try withUnsafeMutablePointer(to: &event) { ptr in
            if epoll_ctl(self.epollFD, EPOLL_CTL_ADD, fd, ptr) == -1 {
                throw POSIXError.fromErrno()
            }
        }
    }

    /// Remove a file descriptor from the monitored collection.
    public func delete(_ fd: Int32) throws {
        var event = epoll_event()
        let result = withUnsafeMutablePointer(to: &event) { ptr in
            epoll_ctl(self.epollFD, EPOLL_CTL_DEL, fd, ptr) as Int32
        }
        if result != 0 {
            if !acceptableDeletionErrno() {
                throw POSIXError.fromErrno()
            }
        }
    }

    /// Wait for events.
    ///
    /// Returns ready events, an empty array on timeout, or `nil` on shutdown.
    public func wait(maxEvents: Int = 128, timeout: Int32 = -1) -> [Event]? {
        var events: [epoll_event] = .init(repeating: epoll_event(), count: maxEvents)

        while true {
            let n = epoll_wait(self.epollFD, &events, Int32(events.count), timeout)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN {
                    continue
                }
                preconditionFailure("epoll_wait failed unexpectedly: \(POSIXError.fromErrno())")
            }

            if n == 0 {
                return []
            }

            var result: [Event] = []
            result.reserveCapacity(Int(n))
            for i in 0..<Int(n) {
                let fd = events[i].data.fd
                if fd == self.eventFD {
                    return nil
                }
                result.append(Event(fd: fd, mask: Mask(rawValue: events[i].events)))
            }
            return result
        }
    }

    /// Signal the epoll loop to stop waiting.
    public func shutdown() {
        var val: UInt64 = 1
        let n = _write(eventFD, &val, MemoryLayout<UInt64>.size)
        precondition(n == MemoryLayout<UInt64>.size, "eventfd write failed: \(POSIXError.fromErrno())")
    }

    // The errno's here are acceptable and can happen if the caller
    // closed the underlying fd before calling delete().
    private func acceptableDeletionErrno() -> Bool {
        errno == ENOENT || errno == EBADF || errno == EPERM
    }
}

#endif  // os(Linux)
