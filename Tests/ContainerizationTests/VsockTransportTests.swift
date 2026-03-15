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

#if os(macOS)

import ContainerizationOS
import Darwin
import Foundation
import Testing

@testable import Containerization

/// Tests for the VsockTransport fd lifecycle fix.
///
/// The Virtualization framework tears down the vsock endpoint when a
/// VZVirtioSocketConnection is closed, invalidating dup'd descriptors.
/// The fix keeps the connection alive via VsockTransport until the gRPC
/// channel is shut down.
///
/// These tests use Unix socket pairs to verify:
/// 1. A dup'd fd is fully functional when the original is kept alive.
/// 2. The specific fcntl call that triggers the NIO crash (F_SETNOSIGPIPE)
///    works on the dup'd fd.
/// 3. The correct teardown order (close dup'd fd first, then original)
///    preserves the connection for the peer until the original is closed.
@Suite("VsockTransport tests")
struct VsockTransportTests {
    private final class CloseCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func count() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct FakeVM: VirtualMachineInstance {
        typealias Agent = Vminitd

        let dialImpl: @Sendable (UInt32) async throws -> VsockConnection

        var state: VirtualMachineInstanceState { .running }
        var mounts: [String: [AttachedFilesystem]] { [:] }

        func dialAgent() async throws -> Vminitd {
            fatalError("unused in test")
        }

        func dial(_ port: UInt32) async throws -> VsockConnection {
            try await dialImpl(port)
        }

        func listen(_ port: UInt32) throws -> VsockListener {
            fatalError("unused in test")
        }

        func start() async throws {
            fatalError("unused in test")
        }

        func stop() async throws {
            fatalError("unused in test")
        }
    }

    /// Creates a connected Unix socket pair. Returns (fd0, fd1).
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try #require(result == 0, "socketpair should succeed")
        return (fds[0], fds[1])
    }

    private func setSocketTimeout(fd: Int32, seconds: Int) throws {
        var timer = timeval()
        timer.tv_sec = seconds
        timer.tv_usec = 0

        let rc = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timer,
            socklen_t(MemoryLayout<timeval>.size)
        )
        try #require(rc == 0, "setting socket timeout should succeed")
    }

    private func uniqueSocketPath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("relay.sock").path
    }

    private func connectUnixSocket(path: String) throws -> Socket {
        var lastError: Error?
        for _ in 0..<50 {
            do {
                let socket = try Socket(type: UnixType(path: path))
                try socket.connect()
                try socket.setTimeout(option: .receive, seconds: 1)
                try socket.setTimeout(option: .send, seconds: 1)
                return socket
            } catch {
                lastError = error
                usleep(20_000)
            }
        }

        throw lastError ?? POSIXError(.ETIMEDOUT)
    }

    // MARK: - fd lifecycle tests

    /// Verifies that F_SETNOSIGPIPE (the exact fcntl call where NIO crashes)
    /// succeeds on a dup'd fd when the original is kept alive.
    @Test func dupdDescriptorSupportsFcntlWhenOriginalAlive() throws {
        let (fd0, fd1) = try makeSocketPair()
        defer {
            close(fd0)
            close(fd1)
        }

        let dupdFd = dup(fd0)
        try #require(dupdFd != -1)
        defer { close(dupdFd) }

        // This is the exact operation that triggers the NIO EBADF crash
        // when the underlying vsock endpoint has been torn down.
        let result = fcntl(dupdFd, F_SETNOSIGPIPE, 1)
        #expect(result == 0, "F_SETNOSIGPIPE should succeed on dup'd fd when original is alive")
    }

    /// Verifies that a dup'd fd can read data written by the peer when the
    /// original fd is kept alive.
    @Test func dupdDescriptorCanReadWhenOriginalAlive() throws {
        let (fd0, fd1) = try makeSocketPair()
        defer {
            close(fd0)
            close(fd1)
        }

        let dupdFd = dup(fd0)
        try #require(dupdFd != -1)
        defer { close(dupdFd) }

        // Peer writes data.
        let message: [UInt8] = [1, 2, 3]
        let writeResult = message.withUnsafeBufferPointer { buf in
            write(fd1, buf.baseAddress, buf.count)
        }
        try #require(writeResult == 3)

        // Dup'd fd can read because the original keeps the connection alive.
        var readBuf = [UInt8](repeating: 0, count: 3)
        let readResult = readBuf.withUnsafeMutableBufferPointer { buf in
            read(dupdFd, buf.baseAddress, buf.count)
        }
        #expect(readResult == 3)
        #expect(readBuf == [1, 2, 3])
    }

    /// Verifies the correct teardown order: closing the dup'd fd first (gRPC
    /// channel shutdown) does not break the connection for the peer, because
    /// the original fd (transport) is still alive.
    @Test func peerCanWriteAfterDupdFdClosedWhileOriginalAlive() throws {
        let (fd0, fd1) = try makeSocketPair()
        defer {
            close(fd0)
            close(fd1)
        }

        let dupdFd = dup(fd0)
        try #require(dupdFd != -1)

        // Close the dup'd fd (simulates gRPC channel shutdown).
        close(dupdFd)

        // The peer can still write because the original fd keeps the
        // connection alive. This matters for orderly shutdown: the guest
        // doesn't see an unexpected EOF while the host is still tearing
        // down the gRPC channel.
        let message: [UInt8] = [42]
        let writeResult = message.withUnsafeBufferPointer { buf in
            write(fd1, buf.baseAddress, buf.count)
        }
        #expect(writeResult == 1, "Peer can still write after dup'd fd is closed")

        // Read from the original to confirm data arrived.
        var readBuf = [UInt8](repeating: 0, count: 1)
        let readResult = readBuf.withUnsafeMutableBufferPointer { buf in
            read(fd0, buf.baseAddress, buf.count)
        }
        #expect(readResult == 1)
        #expect(readBuf == [42])
    }

    /// Verifies that after both the dup'd fd and the original are closed,
    /// the peer sees EOF (read returns 0).
    @Test func peerSeesEOFAfterBothDescriptorsClosed() throws {
        let (fd0, fd1) = try makeSocketPair()
        defer { close(fd1) }

        let dupdFd = dup(fd0)
        try #require(dupdFd != -1)

        // Close dup'd fd first (gRPC shutdown), then original (transport.close()).
        close(dupdFd)
        close(fd0)

        // Peer should see EOF.
        var readBuf = [UInt8](repeating: 0, count: 1)
        let readResult = readBuf.withUnsafeMutableBufferPointer { buf in
            read(fd1, buf.baseAddress, buf.count)
        }
        #expect(readResult == 0, "Peer should see EOF after both descriptors are closed")
    }

    @Test func transportCloseIsIdempotent() {
        let counter = CloseCounter()
        let transport = VsockTransport(onClose: {
            counter.increment()
        })

        transport.close()
        transport.close()

        #expect(counter.count() == 1)
    }

    @Test func retainedConnectionCloseClosesTransportOnce() throws {
        let (fd0, fd1) = try makeSocketPair()
        defer {
            close(fd0)
            close(fd1)
        }

        let dupdFd = dup(fd0)
        try #require(dupdFd != -1)

        let counter = CloseCounter()
        let transport = VsockTransport(onClose: {
            counter.increment()
        })
        let connection = VsockConnection(fileDescriptor: dupdFd, transport: transport)

        try connection.close()
        try connection.close()

        #expect(counter.count() == 1)
    }

    @Test func retainedConnectionDeinitClosesUnderlyingTransport() throws {
        let (fd0, fd1) = try makeSocketPair()
        defer { close(fd1) }

        let dupdFd = dup(fd0)
        try #require(dupdFd != -1)

        let counter = CloseCounter()
        do {
            let connection = VsockConnection(
                fileDescriptor: dupdFd,
                transport: VsockTransport(onClose: {
                    counter.increment()
                    close(fd0)
                })
            )
            _ = connection
        }

        var readBuf = [UInt8](repeating: 0, count: 1)
        let readResult = readBuf.withUnsafeMutableBufferPointer { buf in
            read(fd1, buf.baseAddress, buf.count)
        }
        #expect(readResult == 0, "peer should see EOF after retained handle deallocation")
        #expect(counter.count() == 1)
    }

    @Test func unixSocketRelayRetainsDialedHandleForActiveRelay() async throws {
        let (relayFd, peerFd) = try makeSocketPair()
        defer { close(peerFd) }

        try setSocketTimeout(fd: peerFd, seconds: 1)

        let socketPath = uniqueSocketPath()
        defer {
            try? FileManager.default.removeItem(atPath: (socketPath as NSString).deletingLastPathComponent)
        }

        let relay = try UnixSocketRelay(
            port: 4242,
            socket: UnixSocketConfiguration(
                source: URL(filePath: "/guest/test.sock"),
                destination: URL(filePath: socketPath),
                direction: .outOf
            ),
            vm: FakeVM(dialImpl: { _ in
                VsockConnection(
                    fileDescriptor: relayFd,
                    transport: VsockTransport(onClose: {})
                )
            }),
            queue: DispatchQueue(label: "com.apple.containerization.tests.unix-socket-relay")
        )

        try await relay.start()
        let hostSocket = try connectUnixSocket(path: socketPath)
        defer { try? hostSocket.close() }
        try? await Task.sleep(for: .milliseconds(100))

        let guestToHost = Data("guest-to-host".utf8)
        let guestWriteResult = guestToHost.withUnsafeBytes { ptr in
            write(peerFd, ptr.baseAddress, ptr.count)
        }
        try #require(guestWriteResult == guestToHost.count)

        var hostBuffer = Data(repeating: 0, count: guestToHost.count)
        let hostReadCount = try hostSocket.read(buffer: &hostBuffer)
        #expect(hostReadCount == guestToHost.count)
        #expect(Data(hostBuffer.prefix(hostReadCount)) == guestToHost)

        let hostToGuest = Data("host-to-guest".utf8)
        let hostWriteCount = try hostSocket.write(data: hostToGuest)
        #expect(hostWriteCount == hostToGuest.count)

        var guestBuffer = [UInt8](repeating: 0, count: hostToGuest.count)
        let guestReadCount = guestBuffer.withUnsafeMutableBufferPointer { buf in
            read(peerFd, buf.baseAddress, buf.count)
        }
        #expect(guestReadCount == hostToGuest.count)
        #expect(Data(guestBuffer.prefix(guestReadCount)) == hostToGuest)

        try relay.stop()
    }

    @Test func unixSocketRelayStopReleasesGuestConnections() async throws {
        let (relayFd, peerFd) = try makeSocketPair()
        defer { close(peerFd) }

        let counter = CloseCounter()
        let socketPath = uniqueSocketPath()
        defer {
            try? FileManager.default.removeItem(atPath: (socketPath as NSString).deletingLastPathComponent)
        }

        let relay = try UnixSocketRelay(
            port: 4243,
            socket: UnixSocketConfiguration(
                source: URL(filePath: "/guest/test.sock"),
                destination: URL(filePath: socketPath),
                direction: .outOf
            ),
            vm: FakeVM(dialImpl: { _ in
                VsockConnection(
                    fileDescriptor: relayFd,
                    transport: VsockTransport(onClose: {
                        counter.increment()
                    })
                )
            }),
            queue: DispatchQueue(label: "com.apple.containerization.tests.unix-socket-relay.stop")
        )

        try await relay.start()
        let hostSocket = try connectUnixSocket(path: socketPath)
        defer { try? hostSocket.close() }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(counter.count() == 0)

        try relay.stop()

        // stop() synchronously closes guest connections and releases their transports.
        #expect(counter.count() == 1)
    }
}

#endif
