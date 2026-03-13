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

    /// Creates a connected Unix socket pair. Returns (fd0, fd1).
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try #require(result == 0, "socketpair should succeed")
        return (fds[0], fds[1])
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
}

#endif
