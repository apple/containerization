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

import Foundation
import Synchronization
import Testing

@testable import ContainerizationOS

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@Suite("Socket ownership and cancellation")
struct SocketOwnershipTests {
    private func pair(waitObserver: (@Sendable (Socket.WaitEvent) -> Void)? = nil) throws -> (Socket, Socket) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, _SOCK_STREAM, 0, &fds) == 0)
        let type = try UnixType(path: "/tmp/unused")
        let second = DescriptorTransfer(adopting: fds[1])
        let first = try Socket(fd: fds[0], type: type, closeOnDeinit: true, connected: true, waitObserver: waitObserver)
        return (first, try Socket(fd: second.release(), type: type, closeOnDeinit: true, connected: true))
    }

    private func listener(waitObserver: (@Sendable (Socket.WaitEvent) -> Void)? = nil) throws -> (Socket, UnixType, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let type = try UnixType(path: directory.appendingPathComponent("socket").path)
            let fd = sysSocket(type.domain, type.type, 0)
            try #require(fd >= 0)
            let socket = try Socket(fd: fd, type: type, closeOnDeinit: true, waitObserver: waitObserver)
            try socket.listen()
            return (socket, type, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @Test
    func closePinsUseAndNeverClosesReusedNumber() async throws {
        let fd = open("/dev/null", O_RDONLY)
        try #require(fd >= 0)
        let replacement = open("/dev/zero", O_RDONLY)
        try #require(replacement >= 0)
        defer {
            _ = close(fd)
            _ = close(replacement)
        }
        let attempts = Mutex(0)
        let owner = OwnedDescriptor(
            adopting: fd,
            closeImplementation: { descriptor in
                attempts.withLock { $0 += 1 }
                // Reuse atomically without exposing the number to other tests.
                return dup2(replacement, descriptor) >= 0 ? 0 : -1
            })
        let use = try owner.acquire()
        try owner.close()
        #expect(attempts.withLock { $0 } == 0)
        #expect(throws: SocketError.closed) { _ = try owner.acquire() }
        use.end()
        try await withTestCompletionTimeout { try await owner.closeAndWait() }
        #expect(attempts.withLock { $0 } == 1)
        var byte: UInt8 = 17
        #expect(read(fd, &byte, 1) == 1)
        #expect(byte == 0)
        try owner.close()
        use.end()
        try await withTestCompletionTimeout { try await owner.closeAndWait() }
        #expect(attempts.withLock { $0 } == 1)
        #expect(fcntl(fd, F_GETFD) >= 0)
    }

    private func nonblockingPipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        try #require(pipe(&descriptors) == 0)
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
            let error = errno
            _ = close(descriptors[0])
            _ = close(descriptors[1])
            throw SocketError.withErrno("set pipe nonblocking", errno: error)
        }
        return (descriptors[0], descriptors[1])
    }

    @Test
    func abandonedTransferClosesButConsumedTransferKeepsSameOwner() throws {
        let first = try nonblockingPipe()
        defer { _ = close(first.read) }
        _ = DescriptorTransfer(adopting: first.write)
        var byte: UInt8 = 0
        #expect(read(first.read, &byte, 1) == 0)

        let second = try nonblockingPipe()
        defer { _ = close(second.read) }
        let owner = DescriptorTransfer(adopting: second.write).takeOwner()
        let result = read(second.read, &byte, 1)
        let error = errno
        #expect(result == -1)
        #expect(error == EAGAIN)
        try owner.close()
        #expect(read(second.read, &byte, 1) == 0)
    }

    @Test
    func interruptedCloseIsNeverRetriedAndEveryCallerSeesSameError() async throws {
        let fd = open("/dev/null", O_RDONLY)
        try #require(fd >= 0)
        let attempts = Mutex(0)
        let owner = OwnedDescriptor(
            adopting: fd,
            closeImplementation: { descriptor in
                attempts.withLock { $0 += 1 }
                _ = close(descriptor)
                errno = EINTR
                return -1
            })
        let use = try owner.acquire()
        let waiters = (0..<2).map { _ in
            Task {
                do {
                    try await owner.closeAndWait()
                    return false
                } catch SocketError.withErrno(_, let error) { return error == EINTR } catch { return false }
            }
        }
        waiters[0].cancel()
        try owner.close()
        #expect(attempts.withLock { $0 } == 0)
        use.end()
        try await withTestCompletionTimeout {
            for waiter in waiters { #expect(await waiter.value) }
        }
        #expect(attempts.withLock { $0 } == 1)
        #expect(throws: (any Error).self) { try owner.close() }
        #expect(attempts.withLock { $0 } == 1)
    }

    @Test
    func sendTimeoutBoundsEachWaitForProgress() async throws {
        let (socket, peer) = try pair()
        defer {
            try? socket.close()
            try? peer.close()
        }
        var timeout = timeval()
        timeout.tv_usec = 500_000
        try withUnsafePointer(to: &timeout) { try socket.setSockOpt(sockOpt: SO_SNDTIMEO, ptr: $0, stride: UInt32(MemoryLayout<timeval>.size)) }
        var size: Int32 = 1024
        try withUnsafePointer(to: &size) { try socket.setSockOpt(sockOpt: SO_SNDBUF, ptr: $0, stride: UInt32(MemoryLayout<Int32>.size)) }
        // A writer that gives up early must not leave the reader blocked forever.
        try peer.setTimeout(option: .receive, seconds: 5)
        let payload = Data(count: 64 * 1024)
        let writer = runSocketWorker {
            let started = ContinuousClock.now
            return (try socket.write(data: payload), started.duration(to: .now))
        }
        let reader = runSocketWorker {
            var buffer = Data(count: 4 * 1024)
            var received = 0
            let started = ContinuousClock.now
            while received < payload.count {
                // Paced reads make the write outlast the timeout while each wait stays short.
                if started.duration(to: .now) < .seconds(1) { usleep(50_000) }
                received += try peer.read(buffer: &buffer)
            }
            return received
        }
        let (written, elapsed) = try await writer.value
        #expect(written == payload.count)
        // A write that finished within one timeout would not exercise the restart.
        #expect(elapsed > .milliseconds(500))
        #expect(try await reader.value == payload.count)
    }

    /// Darwin rejects SO_NOSIGPIPE on such a connection; Linux has no equivalent failure.
    @Test
    func acceptDeliversConnectionWhosePeerAlreadyClosed() async throws {
        let (socket, type, directory) = try listener()
        defer {
            try? socket.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let early = try Socket(type: type)
        try early.connect()
        #expect(try early.write(data: Data("early".utf8)) == 5)
        try early.close()
        let stream = try socket.acceptStream()
        try await withTestCompletionTimeout {
            var iterator = stream.makeAsyncIterator()
            let accepted = try #require(try await iterator.next())
            defer { try? accepted.close() }
            var buffer = Data(count: 8)
            #expect(try accepted.read(buffer: &buffer) == 5)
            let live = try Socket(type: type)
            defer { try? live.close() }
            try live.connect()
            let next = try #require(try await iterator.next())
            try next.close()
        }
    }

    @Test
    func manualLifetimeDoesNotClosePayload() throws {
        let fd: Int32
        do {
            let socket = try Socket(type: UnixType(path: "/tmp/unused"), closeOnDeinit: false)
            fd = socket.fileDescriptor
        }
        defer { _ = close(fd) }
        #expect(fcntl(fd, F_GETFD) >= 0)
    }

    @Test
    func closeInterruptsMultipleSilentReads() async throws {
        let (events, readiness) = AsyncStream<Void>.makeStream()
        defer { readiness.finish() }
        let (socket, peer) = try pair(waitObserver: { event in
            if event == .synchronousWait { readiness.yield() }
        })
        defer {
            try? socket.close()
            try? peer.close()
        }
        try socket.setTimeout(option: .receive, seconds: 5)
        let tasks = (0..<2).map { _ in
            runSocketWorker { () -> Bool in
                var buffer = Data(count: 16)
                do {
                    _ = try socket.read(buffer: &buffer)
                    return false
                } catch SocketError.closed { return true } catch { return false }
            }
        }
        try await withTestCompletionTimeout { for await _ in events.prefix(2) {} }
        try await withTestCompletionTimeout {
            try await socket.closeAndWait()
            for task in tasks { #expect(try await task.value) }
        }
    }

    @Test
    func closeInterruptsBackpressuredWrite() async throws {
        let (events, readiness) = AsyncStream<Void>.makeStream()
        defer { readiness.finish() }
        let (socket, peer) = try pair(waitObserver: { event in
            if event == .synchronousWait { readiness.yield() }
        })
        defer {
            try? socket.close()
            try? peer.close()
        }
        try socket.setTimeout(option: .send, seconds: 5)
        var size: Int32 = 1024
        try withUnsafePointer(to: &size) { try socket.setSockOpt(sockOpt: SO_SNDBUF, ptr: $0, stride: UInt32(MemoryLayout<Int32>.size)) }
        let task = runSocketWorker { () -> Bool in
            do {
                _ = try socket.write(data: Data(repeating: 17, count: 16 * 1024 * 1024))
                return false
            } catch SocketError.closed { return true } catch { return false }
        }
        try await withTestCompletionTimeout { for await _ in events.prefix(1) {} }
        try await withTestCompletionTimeout {
            try await socket.closeAndWait()
            #expect(try await task.value)
        }
    }

    @Test
    func partialWritesDeliverEachByteOnce() async throws {
        let (socket, peer) = try pair()
        defer {
            try? socket.close()
            try? peer.close()
        }
        try socket.setTimeout(option: .send, seconds: 5)
        try peer.setTimeout(option: .receive, seconds: 5)
        var size: Int32 = 1024
        try withUnsafePointer(to: &size) { try socket.setSockOpt(sockOpt: SO_SNDBUF, ptr: $0, stride: UInt32(MemoryLayout<Int32>.size)) }
        let payload = Data((0..<256_000).map { UInt8(truncatingIfNeeded: $0) })
        let writer = runSocketWorker {
            var regions = DispatchData.empty
            payload.withUnsafeBytes { bytes in
                regions.append(DispatchData(bytes: UnsafeRawBufferPointer(rebasing: bytes[..<31])))
                regions.append(DispatchData(bytes: UnsafeRawBufferPointer(rebasing: bytes[31..<8000])))
                regions.append(DispatchData(bytes: UnsafeRawBufferPointer(rebasing: bytes[8000...])))
            }
            return try socket.write(data: regions)
        }
        let reader = runSocketWorker {
            var received = Data()
            var buffer = Data(count: 137)
            while received.count < payload.count {
                let count = try peer.read(buffer: &buffer)
                received.append(buffer.prefix(count))
            }
            return received
        }
        try await withTestCompletionTimeout { () async throws -> Void in
            #expect(try await writer.value == payload.count)
            #expect(try await reader.value == payload)
        }
    }

    @Test
    func silentReadWaitsForReceiveTimeout() async throws {
        let (socket, peer) = try pair()
        defer {
            try? socket.close()
            try? peer.close()
        }
        var timeout = timeval()
        timeout.tv_usec = 20_000
        try withUnsafePointer(to: &timeout) { try socket.setSockOpt(sockOpt: SO_RCVTIMEO, ptr: $0, stride: UInt32(MemoryLayout<timeval>.size)) }
        let reader = runSocketWorker { () -> (error: Int32?, elapsed: Duration) in
            var buffer = Data(count: 1)
            let started = ContinuousClock.now
            do {
                _ = try socket.read(buffer: &buffer)
                return (nil, started.duration(to: .now))
            } catch SocketError.withErrno(_, let error) {
                return (error, started.duration(to: .now))
            }
        }
        let result = try await withTestCompletionTimeout { try await reader.value }
        #expect(result.error == EAGAIN)
        #expect(result.elapsed >= .milliseconds(20))
    }

    @Test(arguments: [false, true])
    func acceptStreamCancellationReleasesRegistrationAndReservation(closeListener: Bool) async throws {
        let (events, readiness) = AsyncStream<Void>.makeStream()
        defer { readiness.finish() }
        let (socket, _, directory) = try listener(waitObserver: { event in
            if event == .acceptSourceActivated { readiness.yield() }
        })
        defer {
            try? socket.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let task = Task {
            let stream = try socket.acceptStream()
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        defer { task.cancel() }
        try await withTestCompletionTimeout { for await _ in events.prefix(1) {} }
        try await withTestCompletionTimeout {
            if closeListener {
                try await socket.closeAndWait()
            } else {
                task.cancel()
            }
            #expect(try await task.value == nil)
            if closeListener {
                #expect(socket.fileDescriptor == -1)
            } else {
                let owner = try socket.takeDescriptor().takeOwner()
                try await owner.closeAndWait()
            }
        }
    }

    @Test
    func closingIdleStreamFinishesNext() async throws {
        let (socket, _, directory) = try listener()
        defer {
            try? socket.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let stream = try socket.acceptStream()
        try await withTestCompletionTimeout {
            try await socket.closeAndWait()
            var iterator = stream.makeAsyncIterator()
            #expect(try await iterator.next() == nil)
        }
    }

    @Test
    func detachedFileHandleIsBlockingAndOwnsDescriptor() throws {
        let (socket, peer) = try pair()
        defer { try? peer.close() }
        let handle = try socket.detachFileHandle()
        #expect(socket.fileDescriptor == -1)
        #expect(fcntl(handle.fileDescriptor, F_GETFL) & O_NONBLOCK == 0)
        #expect(try peer.write(data: Data([7])) == 1)
        #expect(handle.availableData == Data([7]))
    }

    #if os(Linux)
    @Test
    func fullUnixBacklogConnectWaitsForSpace() async throws {
        let (listeningSocket, type, directory) = try listener()
        defer {
            try? listeningSocket.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try #require(sysListen(listeningSocket.fileDescriptor, 0) == 0)
        // Linux allows one queued connection with backlog zero.
        let queued = try Socket(type: type)
        defer { try? queued.close() }
        try queued.connect()

        let (events, readiness) = AsyncStream<Void>.makeStream()
        defer { readiness.finish() }
        let fd = sysSocket(type.domain, type.type, 0)
        try #require(fd >= 0)
        let observer: @Sendable (Socket.WaitEvent) -> Void = { if $0 == .synchronousWait { readiness.yield() } }
        let socket = try Socket(fd: fd, type: type, closeOnDeinit: true, waitObserver: observer)
        defer { try? socket.close() }
        let connecting = runSocketWorker { try socket.connect() }
        try await withTestCompletionTimeout { for await _ in events.prefix(1) {} }
        let accepted = try listeningSocket.accept()
        defer { try? accepted.close() }
        try await withTestCompletionTimeout { try await connecting.value }
        #expect(try socket.write(data: Data([1])) == 1)
    }
    #endif
}

/// Blocking test I/O must not exhaust Swift's cooperative executor.
private func runSocketWorker<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) -> Task<Value, any Error> {
    Task {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}
