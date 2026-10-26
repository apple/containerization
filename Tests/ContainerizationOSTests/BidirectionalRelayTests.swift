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
import Testing

@testable import ContainerizationOS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("BidirectionalRelay tests")
final class BidirectionalRelayTests {
    // Raw write() to a socketpair whose peer is closed must not kill the
    // `swift test` process with SIGPIPE on Linux. See ignoreSIGPIPEForTests().
    init() { ignoreSIGPIPEForTests() }

    /// Creates a Unix domain socket pair and returns (fd0, fd1).
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, _SOCK_STREAM, 0, &fds)
        try #require(result == 0, "socketpair should succeed, errno: \(errno)")
        return (fds[0], fds[1])
    }

    /// Writes all bytes to a file descriptor, retrying on partial writes.
    private func writeAll(fd: Int32, data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress?.advanced(by: offset), data.count - offset)
            }
            try #require(n > 0, "write failed, errno: \(errno)")
            offset += n
        }
    }

    /// Reads exactly `count` bytes from a file descriptor with a timeout.
    /// Returns the data read, or nil if the timeout expires.
    private func readWithTimeout(fd: Int32, count: Int, timeoutSeconds: Double) -> [UInt8]? {
        // Set fd to non-blocking so reads cannot outlast the timeout.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }

        var result = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while totalRead < count && Date() < deadline {
            let n = result.withUnsafeMutableBufferPointer { buf in
                read(fd, buf.baseAddress?.advanced(by: totalRead), count - totalRead)
            }
            if n > 0 {
                totalRead += n
            } else if n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Not ready yet, brief sleep before retry.
                usleep(1000)  // 1ms
            } else {
                break
            }
        }
        return totalRead == count ? result : nil
    }

    /// Sets a small send buffer on a socket to make it fill quickly.
    private func setSendBufferSize(fd: Int32, size: Int32) {
        var bufSize = size
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Waits until the relay's destination stops accepting data, so the relay is backpressured.
    private func waitUntilFull(_ fd: Int32) throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&event, 1, 0) == 0 { return }
            try #require(Date() < deadline, "relay destination never filled")
            usleep(1000)
        }
    }

    // MARK: - Test 1: Basic relay

    @Test
    func testBasicRelay() throws {
        // Create two socketpairs:
        //   pair1: a0 <-> a1
        //   pair2: b0 <-> b1
        // The relay connects a1 <-> b0.
        // Write to a0, read from b1 (data flows: a0 → a1 → relay → b0 → b1).
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()
        defer {
            close(a0)
            close(b1)
        }

        let relay = try BidirectionalRelay(fd1: a1, fd2: b0)
        defer { relay.stop() }
        try relay.start()

        let testData: [UInt8] = Array("Hello, BidirectionalRelay!".utf8)
        try writeAll(fd: a0, data: testData)

        let received = readWithTimeout(fd: b1, count: testData.count, timeoutSeconds: 2.0)
        #expect(received == testData, "Data should pass through the relay")

        // Test the reverse direction: write to b1, read from a0.
        let reverseData: [UInt8] = Array("Reverse direction".utf8)
        try writeAll(fd: b1, data: reverseData)

        let reverseReceived = readWithTimeout(fd: a0, count: reverseData.count, timeoutSeconds: 2.0)
        #expect(reverseReceived == reverseData, "Data should flow in reverse through the relay")
    }

    // MARK: - Test 2: Cross-connection head-of-line blocking

    @Test
    func testNoCrossConnectionBlocking() throws {
        // Two relays sharing a single serial queue (simulating the old architecture).
        // One relay's destination is saturated (not drained).
        // The other relay should still work — proving per-connection isolation.
        let sharedQueue = DispatchQueue(label: "test.shared-queue")

        // Relay 1: a0 → a1 --relay1--> b0 → b1 (b1 won't be read, causing backpressure)
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()

        // Relay 2: c0 → c1 --relay2--> d0 → d1 (d1 will be read normally)
        let (c0, c1) = try makeSocketPair()
        let (d0, d1) = try makeSocketPair()

        defer {
            close(a0)
            close(b1)
            close(c0)
            close(d1)
        }

        // Shrink send buffers to make them fill quickly.
        setSendBufferSize(fd: b0, size: 4096)

        let relay1 = try BidirectionalRelay(fd1: a1, fd2: b0, queue: sharedQueue)
        let relay2 = try BidirectionalRelay(fd1: c1, fd2: d0, queue: sharedQueue)
        defer {
            relay1.stop()
            relay2.stop()
        }

        try relay1.start()
        try relay2.start()

        // Saturate relay1: write data into a0 but never read from b1.
        // This fills b0's send buffer, triggering backpressure on relay1.
        let largeData = [UInt8](repeating: 0x41, count: 65536)
        // Use non-blocking write to a0 so we don't block this test thread.
        let a0flags = fcntl(a0, F_GETFL)
        _ = fcntl(a0, F_SETFL, a0flags | O_NONBLOCK)
        _ = largeData.withUnsafeBufferPointer { buf in
            write(a0, buf.baseAddress, buf.count)
        }
        _ = fcntl(a0, F_SETFL, a0flags)  // restore

        // Wait for relay1 to process the data and become backpressured.
        try waitUntilFull(b0)

        // Now test relay2: it should still work despite relay1 being backpressured.
        let testData: [UInt8] = Array("relay2 works!".utf8)
        try writeAll(fd: c0, data: testData)

        let received = readWithTimeout(fd: d1, count: testData.count, timeoutSeconds: 2.0)
        #expect(received != nil, "Relay2 should not be blocked by Relay1's backpressure")
        if let received {
            #expect(received == testData, "Relay2 data should be correct")
        }
    }

    // MARK: - Test 3: Backpressure recovery

    @Test
    func testBackpressureRecovery() throws {
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()
        defer {
            close(a0)
            close(b1)
        }
        // Shrink send buffers so backpressure kicks in quickly.
        setSendBufferSize(fd: a0, size: 4096)
        setSendBufferSize(fd: b0, size: 4096)
        for fd in [a0, b1] {
            let flags = fcntl(fd, F_GETFL)
            try #require(flags >= 0)
            try #require(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
        }

        let relay = try BidirectionalRelay(fd1: a1, fd2: b0)
        defer { relay.stop() }
        try relay.start()

        // Write enough data to trigger backpressure (more than the send buffer).
        let payload = (0..<65_536).map { UInt8(truncatingIfNeeded: $0) }
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var sent = 0
        var backpressured = false
        let deadline = ContinuousClock.now + .seconds(5)
        while received.count < payload.count && ContinuousClock.now < deadline {
            if sent < payload.count {
                let count = payload.withUnsafeBufferPointer { bytes in
                    write(a0, bytes.baseAddress?.advanced(by: sent), payload.count - sent)
                }
                if count > 0 {
                    sent += count
                    if sent == payload.count {
                        try #require(shutdown(a0, Int32(SHUT_WR)) == 0)
                    }
                } else if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    backpressured = true
                } else if count != -1 || errno != EINTR {
                    try #require(count > 0, "write failed, errno: \(errno)")
                }
            }
            if !backpressured { continue }
            // Read from b1 (drain) — this should relieve backpressure.
            let count = buffer.withUnsafeMutableBytes { read(b1, $0.baseAddress, $0.count) }
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
            } else if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var event = pollfd(fd: b1, events: Int16(POLLIN), revents: 0)
                _ = poll(&event, 1, 10)
            } else if count != -1 || errno != EINTR {
                try #require(count > 0, "read failed, errno: \(errno)")
            }
        }
        #expect(backpressured)
        #expect(sent == payload.count)
        #expect(received == payload)
        #expect(peerSeesEOF(b1), "EOF should follow the buffered payload after backpressure clears")
    }

    // MARK: - Test 4: EOF handling

    @Test
    func testEOFHandling() async throws {
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()
        let firstPeer = FileHandle(fileDescriptor: a0, closeOnDealloc: true)
        let secondPeer = FileHandle(fileDescriptor: b1, closeOnDealloc: true)
        defer {
            try? firstPeer.close()
            try? secondPeer.close()
        }

        let relay = try BidirectionalRelay(fd1: a1, fd2: b0)
        defer { relay.stop() }
        try relay.start()

        // Write some data, then close one end.
        let testData: [UInt8] = Array("goodbye".utf8)
        try writeAll(fd: a0, data: testData)
        try firstPeer.close()

        // Read the data from the other end.
        let received = readWithTimeout(fd: b1, count: testData.count, timeoutSeconds: 2.0)
        #expect(received == testData, "Data should arrive before EOF")

        // Close b1 as well so both directions see EOF.
        // (a0 closed → a1 reads EOF → source1 done;
        //  b1 closed → b0 reads EOF → source2 done → relay complete)
        try secondPeer.close()

        // The relay should detect EOF on both directions and complete.
        try await withTestCompletionTimeout { await relay.waitForCompletion() }
    }

    // MARK: - Test 5: Stop while under backpressure

    @Test
    func testStopWhileBackpressured() async throws {
        // Verify that stop() works correctly when a read source is suspended
        // due to backpressure. Previously, cancelling a suspended dispatch source
        // would never deliver the cancel handler, leaking file descriptors.
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()
        defer {
            // Close the external ends after stopping the relay.
            close(a0)
            close(b1)
        }

        // Shrink b0's send buffer so backpressure kicks in quickly.
        setSendBufferSize(fd: b0, size: 4096)

        let relay = try BidirectionalRelay(fd1: a1, fd2: b0)
        defer { relay.stop() }
        try relay.start()

        // Write enough to trigger backpressure but don't read from b1.
        let largeData = [UInt8](repeating: 0x42, count: 65536)
        let a0flags = fcntl(a0, F_GETFL)
        _ = fcntl(a0, F_SETFL, a0flags | O_NONBLOCK)
        _ = largeData.withUnsafeBufferPointer { buf in
            write(a0, buf.baseAddress, buf.count)
        }

        // Wait until the relay's destination buffer is full.
        try waitUntilFull(b0)

        // Stop the relay while it's backpressured. This should not hang or leak.
        relay.stop()
        relay.stop()

        // The relay should complete (cancel handlers should have fired).
        try await withTestCompletionTimeout { await relay.waitForCompletion() }
        #expect(throws: (any Error).self) { try relay.start() }
    }

    private func peerSeesEOF(_ fd: Int32) -> Bool {
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var result: Int32
        repeat { result = poll(&event, 1, 2000) } while result < 0 && errno == EINTR
        guard result > 0 else { return false }
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 0
    }

    @Test
    func startedRelayOutlivesItsLastReference() throws {
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()
        defer {
            close(a0)
            close(b1)
        }
        try BidirectionalRelay(fd1: a1, fd2: b0).start()
        let data = Array("still relaying".utf8)
        try writeAll(fd: a0, data: data)
        #expect(readWithTimeout(fd: b1, count: data.count, timeoutSeconds: 2.0) == data)
    }

    /// Darwin rejects SO_NOSIGPIPE once the peer has closed; Linux has no equivalent failure.
    @Test
    func startForwardsDataFromPeerThatAlreadyClosed() throws {
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()
        defer { close(b1) }
        let data = Array("request".utf8)
        try writeAll(fd: a0, data: data)
        close(a0)
        let relay = try BidirectionalRelay(fd1: a1, fd2: b0)
        defer { relay.stop() }
        try relay.start()
        #expect(readWithTimeout(fd: b1, count: data.count, timeoutSeconds: 2.0) == data)
        #expect(peerSeesEOF(b1))
    }

    @Test
    func stoppingBeforeStartClosesBothEndpointsAndCompletes() async throws {
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()
        defer {
            close(a0)
            close(b1)
        }
        let relay = try BidirectionalRelay(fd1: a1, fd2: b0)
        defer { relay.stop() }
        relay.stop()
        try await withTestCompletionTimeout { await relay.waitForCompletion() }
        #expect(throws: (any Error).self) { try relay.start() }
        #expect(peerSeesEOF(a0))
        #expect(peerSeesEOF(b1))
    }

    @Test
    func invalidDescriptorsThrowAndStayWithCaller() throws {
        let (a0, a1) = try makeSocketPair()
        defer {
            close(a0)
            close(a1)
        }
        #expect(throws: (any Error).self) { try BidirectionalRelay(fd1: a1, fd2: -1) }
        #expect(throws: (any Error).self) { try BidirectionalRelay(fd1: a1, fd2: a1) }
        #expect(fcntl(a1, F_GETFD) >= 0)
    }
}
