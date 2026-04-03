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

    /// Creates a Unix domain socket pair and returns (fd0, fd1).
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try #require(result == 0, "socketpair should succeed, errno: \(errno)")
        return (fds[0], fds[1])
    }

    /// Writes all bytes to a file descriptor, retrying on partial writes.
    private func writeAll(fd: Int32, data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress!.advanced(by: offset), data.count - offset)
            }
            try #require(n > 0, "write failed, errno: \(errno)")
            offset += n
        }
    }

    /// Reads exactly `count` bytes from a file descriptor with a timeout.
    /// Returns the data read, or nil if the timeout expires.
    private func readWithTimeout(fd: Int32, count: Int, timeoutSeconds: Double) -> [UInt8]? {
        // Set fd to non-blocking for poll-based reading.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }

        var result = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while totalRead < count && Date() < deadline {
            let n = result.withUnsafeMutableBufferPointer { buf in
                read(fd, buf.baseAddress!.advanced(by: totalRead), count - totalRead)
            }
            if n > 0 {
                totalRead += n
            } else if n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Not ready yet, brief sleep before retry.
                usleep(1000) // 1ms
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

    // MARK: - Test 1: Basic relay

    @Test
    func testBasicRelay() throws {
        // Create two socketpairs:
        //   pair1: (a0) --- relay ---> (b0)
        //   pair2: (a1) <-- relay --- (b1)
        // The relay connects a1 <-> b0.
        // Write to a0, read from b1 (data flows: a0 → a1 → relay → b0 → b1).
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()
        defer {
            close(a0)
            close(b1)
        }

        let relay = BidirectionalRelay(fd1: a1, fd2: b0)
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

        relay.stop()
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
            close(a0); close(b1)
            close(c0); close(d1)
        }

        // Shrink send buffers to make them fill quickly.
        setSendBufferSize(fd: b0, size: 4096)

        let relay1 = BidirectionalRelay(fd1: a1, fd2: b0, queue: sharedQueue)
        let relay2 = BidirectionalRelay(fd1: c1, fd2: d0, queue: sharedQueue)

        try relay1.start()
        try relay2.start()

        // Saturate relay1: write data into a0 but never read from b1.
        // This fills b0's send buffer, triggering backpressure on relay1.
        let largeData = [UInt8](repeating: 0x41, count: 65536)
        // Use non-blocking write to a0 so we don't block this test thread.
        let a0flags = fcntl(a0, F_GETFL)
        _ = fcntl(a0, F_SETFL, a0flags | O_NONBLOCK)
        _ = largeData.withUnsafeBufferPointer { buf in
            write(a0, buf.baseAddress!, buf.count)
        }
        _ = fcntl(a0, F_SETFL, a0flags) // restore

        // Give relay1 time to process and get blocked.
        usleep(100_000) // 100ms

        // Now test relay2: it should still work despite relay1 being backpressured.
        let testData: [UInt8] = Array("relay2 works!".utf8)
        try writeAll(fd: c0, data: testData)

        let received = readWithTimeout(fd: d1, count: testData.count, timeoutSeconds: 2.0)
        #expect(received != nil, "Relay2 should not be blocked by Relay1's backpressure")
        if let received {
            #expect(received == testData, "Relay2 data should be correct")
        }

        relay1.stop()
        relay2.stop()
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

        // Shrink b0's send buffer so backpressure kicks in quickly.
        setSendBufferSize(fd: b0, size: 4096)

        let relay = BidirectionalRelay(fd1: a1, fd2: b0)
        try relay.start()

        // Write enough data to trigger backpressure (more than the send buffer).
        let totalBytes = 32768
        let sendData = [UInt8]((0..<totalBytes).map { UInt8($0 & 0xFF) })

        // Write in a background thread since it may partially block.
        let writeThread = Thread {
            var offset = 0
            while offset < sendData.count {
                let n = sendData.withUnsafeBufferPointer { buf in
                    write(a0, buf.baseAddress!.advanced(by: offset), min(4096, sendData.count - offset))
                }
                if n > 0 {
                    offset += n
                } else if n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    usleep(1000)
                } else {
                    break
                }
            }
        }
        writeThread.start()

        // Read from b1 (drain) — this should relieve backpressure.
        var received = [UInt8]()
        let readBuf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 4096)
        defer { readBuf.deallocate() }

        let deadline = Date().addingTimeInterval(5.0)
        let b1flags = fcntl(b1, F_GETFL)
        _ = fcntl(b1, F_SETFL, b1flags | O_NONBLOCK)

        while received.count < totalBytes && Date() < deadline {
            let n = read(b1, readBuf.baseAddress!, readBuf.count)
            if n > 0 {
                received.append(contentsOf: UnsafeBufferPointer(start: readBuf.baseAddress!, count: n))
            } else if n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(1000)
            } else {
                break
            }
        }

        #expect(received.count == totalBytes, "All bytes should be received after backpressure recovery (got \(received.count)/\(totalBytes))")
        #expect(received == sendData, "Received data should match sent data")

        relay.stop()
    }

    // MARK: - Test 4: EOF handling

    @Test
    func testEOFHandling() async throws {
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()

        let relay = BidirectionalRelay(fd1: a1, fd2: b0)
        try relay.start()

        // Write some data, then close one end.
        let testData: [UInt8] = Array("goodbye".utf8)
        try writeAll(fd: a0, data: testData)
        close(a0)

        // Read the data from the other end.
        let received = readWithTimeout(fd: b1, count: testData.count, timeoutSeconds: 2.0)
        #expect(received == testData, "Data should arrive before EOF")

        // Close b1 as well so both directions see EOF.
        // (a0 closed → a1 reads EOF → source1 done;
        //  b1 closed → b0 reads EOF → source2 done → relay complete)
        close(b1)

        // The relay should detect EOF on both directions and complete.
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await relay.waitForCompletion()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                return false
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }

        #expect(completed, "Relay should complete after both sides reach EOF")
    }

    // MARK: - Test 5: Stop while under backpressure

    @Test
    func testStopWhileBackpressured() async throws {
        // Verify that stop() works correctly when a read source is suspended
        // due to backpressure. Previously, cancelling a suspended dispatch source
        // would never deliver the cancel handler, leaking file descriptors.
        let (a0, a1) = try makeSocketPair()
        let (b0, b1) = try makeSocketPair()

        // Shrink b0's send buffer so backpressure kicks in quickly.
        setSendBufferSize(fd: b0, size: 4096)

        let relay = BidirectionalRelay(fd1: a1, fd2: b0)
        try relay.start()

        // Write enough to trigger backpressure but don't read from b1.
        let largeData = [UInt8](repeating: 0x42, count: 65536)
        let a0flags = fcntl(a0, F_GETFL)
        _ = fcntl(a0, F_SETFL, a0flags | O_NONBLOCK)
        _ = largeData.withUnsafeBufferPointer { buf in
            write(a0, buf.baseAddress!, buf.count)
        }

        // Give relay time to enter backpressure state (readSource suspended).
        usleep(100_000) // 100ms

        // Stop the relay while it's backpressured. This should not hang or leak.
        relay.stop()

        // Close the external ends — the relay's fds should already be closed by stop().
        close(a0)
        close(b1)

        // The relay should complete (cancel handlers should have fired).
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await relay.waitForCompletion()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                return false
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }

        #expect(completed, "Relay should complete after stop() even when backpressured")
    }
}
