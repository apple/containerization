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

    private enum Endpoint {
        case legacy(FileHandle)
        case owned(OwnedDescriptor)
        case borrowed(OwnedDescriptor)
        case terminal(OwnedDescriptor)

        func prepareOwner() throws -> OwnedDescriptor {
            switch self {
            case .legacy(let source):
                return try Self.duplicate(source.fileDescriptor)
            case .owned(let owner):
                return owner
            case .borrowed(let owner), .terminal(let owner):
                let use = try owner.acquire()
                return try withExtendedLifetime(use) { try Self.duplicate(use.fileDescriptor) }
            }
        }

        private static func duplicate(_ fd: Int32) throws -> OwnedDescriptor {
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw POSIXError.fromErrno() }
            return OwnedDescriptor(adopting: copy)
        }

        func close() throws {
            switch self {
            case .legacy(let source): try source.close()
            case .owned(let owner), .terminal(let owner): try owner.close()
            case .borrowed: break
            }
        }
    }

    private struct IO {
        let from: Endpoint
        let to: Endpoint
        let buffer: UnsafeMutableBufferPointer<UInt8>
        var closed = false
        var closing = false
        var readFinished = false
        var bufferedBytes = 0
        var writeOffset = 0
        var readOwner: OwnedDescriptor?
        var writeOwner: OwnedDescriptor?
        var reader: OSFile?
        var writer: OSFile?
        var registeredFds: [Int32] = []

        mutating func drain(logger: Logger?) {
            guard !self.closed else { return }
            guard let reader, let writer else {
                self.close(logger: logger)
                return
            }

            while true {
                if self.bufferedBytes > 0 {
                    let view = UnsafeMutableBufferPointer(
                        start: self.buffer.baseAddress?.advanced(by: self.writeOffset),
                        count: self.bufferedBytes
                    )
                    let result = writer.write(view)
                    self.writeOffset += result.wrote
                    self.bufferedBytes -= result.wrote
                    switch result.action {
                    case .error(let errno):
                        logger?.error("failed with errno \(errno) while writing for fd \(writer.fileDescriptor)")
                        fallthrough
                    case .brokenPipe:
                        self.close(logger: logger)
                        return
                    case .again:
                        if self.closing {
                            var event = pollfd(fd: writer.fileDescriptor, events: 0, revents: 0)
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

                let result = reader.read(self.buffer)
                self.bufferedBytes = result.read
                self.writeOffset = 0
                switch result.action {
                case .error(let errno):
                    logger?.error("failed with errno \(errno) while reading for fd \(reader.fileDescriptor)")
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
            // Copied callbacks keep descriptor uses alive after unregister.
            try? self.readOwner?.close()
            try? self.writeOwner?.close()
            self.readOwner = nil
            self.writeOwner = nil
            self.reader = nil
            self.writer = nil

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

    private init(readFrom: Endpoint, writeTo: Endpoint, reason: String, logger: Logger?) {
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))
        self.io = Mutex(IO(from: readFrom, to: writeTo, buffer: buffer))
        self.reason = reason
        self.logger = logger
    }

    convenience init(readFrom: FileHandle, writeTo: FileHandle, reason: String, logger: Logger? = nil) {
        self.init(readFrom: .legacy(readFrom), writeTo: .legacy(writeTo), reason: reason, logger: logger)
    }

    convenience init(readFrom: consuming DescriptorTransfer, writeTo: FileHandle, reason: String, logger: Logger? = nil) {
        self.init(readFrom: .owned(readFrom.takeOwner()), writeTo: .legacy(writeTo), reason: reason, logger: logger)
    }

    convenience init(readFrom: FileHandle, writeTo: consuming DescriptorTransfer, reason: String, logger: Logger? = nil) {
        self.init(readFrom: .legacy(readFrom), writeTo: .owned(writeTo.takeOwner()), reason: reason, logger: logger)
    }

    convenience init(readFrom: consuming DescriptorTransfer, writeToBorrowed owner: OwnedDescriptor, reason: String, logger: Logger? = nil) {
        self.init(readFrom: .owned(readFrom.takeOwner()), writeTo: .borrowed(owner), reason: reason, logger: logger)
    }

    /// Relays a session's terminal output. Ending the relay closes the master, so the
    /// terminal hangs up once its stdin relay has also closed its duplicate.
    convenience init(readFromTerminal owner: OwnedDescriptor, writeTo: consuming DescriptorTransfer, reason: String, logger: Logger? = nil) {
        self.init(readFrom: .terminal(owner), writeTo: .owned(writeTo.takeOwner()), reason: reason, logger: logger)
    }

    deinit {
        self.io.withLock { $0.close(logger: self.logger) }
    }

    func relay(ignoreHup: Bool = false) throws {
        self.logger?.info("setting up relay for \(reason)")
        try self.io.withLock { io in
            guard !io.closed, io.readOwner == nil else { return }
            do {
                // Own the active descriptors so a deferred drain survives the caller's close.
                // Distinct descriptors also allow both terminal directions to monitor the shared PTY.
                // Epoll's O_NONBLOCK change remains shared with pipe/PTY originals.
                let readOwner = try io.from.prepareOwner()
                io.readOwner = readOwner
                let writeOwner = try io.to.prepareOwner()
                io.writeOwner = writeOwner
                let readUse = try readOwner.acquire()
                let writeUse = try writeOwner.acquire()
                let readFd = readUse.fileDescriptor
                let writeFd = writeUse.fileDescriptor
                io.reader = OSFile(fd: readFd)
                io.writer = OSFile.writer(fd: writeFd)

                try ProcessSupervisor.default.registerFd(writeFd, mask: .output) { [readUse, writeUse] mask in
                    defer { withExtendedLifetime((readUse, writeUse)) {} }
                    self.io.withLock { io in
                        guard !io.closed else { return }
                        if mask.isHangup && !ignoreHup {
                            io.close(logger: self.logger)
                            return
                        }
                        io.drain(logger: self.logger)
                    }
                }
                io.registeredFds.append(writeFd)
                try ProcessSupervisor.default.registerFd(readFd, mask: .input) { [readUse, writeUse] mask in
                    defer { withExtendedLifetime((readUse, writeUse)) {} }
                    self.io.withLock { io in
                        guard !io.closed else { return }
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
