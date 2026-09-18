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

import Foundation
import Testing

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

@testable import VminitdCore

@Suite("I/O pair tests", .serialized)
struct IOPairTests {
    private struct CloseObserver: IOCloser {
        let handle: FileHandle
        let closed: DispatchSemaphore

        var fileDescriptor: Int32 { handle.fileDescriptor }

        func close() throws {
            try handle.close()
            closed.signal()
        }
    }

    private func write(_ bytes: [UInt8], to fd: Int32) throws {
        try #require(bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) } == bytes.count)
    }

    private func fill(_ fd: Int32) throws -> Int {
        let flags = fcntl(fd, F_GETFL)
        try #require(flags >= 0)
        try #require(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let bytes = [UInt8](repeating: 0xAA, count: 4096)
        var total = 0
        while true {
            let count = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
            if count == -1 {
                try #require(errno == EAGAIN)
                return total
            }
            try #require(count > 0)
            total += count
        }
    }

    private func read(from fd: Int32) throws -> [UInt8] {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        var bytes = [UInt8](repeating: 0, count: 4096)
        var result: [UInt8] = []
        while true {
            try #require(clock.now < deadline, "Timed out reading relayed data")
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 100)
            if ready == 0 || (ready == -1 && errno == EINTR) { continue }
            try #require(ready > 0)
            let received = Foundation.read(fd, &bytes, bytes.count)
            if received == -1 && (errno == EAGAIN || errno == EINTR) { continue }
            try #require(received >= 0)
            if received == 0 { return result }
            result.append(contentsOf: bytes.prefix(received))
        }
    }

    private func drain(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 4096)
        while Foundation.read(fd, &bytes, bytes.count) > 0 {}
    }

    @Test(arguments: [false, true])
    func backpressurePreservesDataAndKeepsSupervisorResponsive(closeExplicitly: Bool) throws {
        let source = Pipe()
        let destination = Pipe()
        let probe = Pipe()
        let sourceFD = source.fileHandleForReading.fileDescriptor
        let destinationFD = destination.fileHandleForReading.fileDescriptor
        let probeFD = probe.fileHandleForReading.fileDescriptor
        let filled = try fill(destination.fileHandleForWriting.fileDescriptor)
        let pair = IOPair(readFrom: source.fileHandleForReading, writeTo: destination.fileHandleForWriting, reason: "backpressure test")
        defer {
            drain(destinationFD)
            pair.close()
            try? ProcessSupervisor.default.unregisterFd(probeFD)
            for pipe in [source, destination, probe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        try pair.relay()
        let payload = (0..<1024).map { UInt8(truncatingIfNeeded: $0) }
        try write(payload, to: source.fileHandleForWriting.fileDescriptor)

        // Observe the source drain so an unrelated event cannot win a race with the blocked write.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while true {
            var event = pollfd(fd: sourceFD, events: Int16(POLLIN), revents: 0)
            try #require(poll(&event, 1, 0) >= 0)
            if event.revents & Int16(POLLIN) == 0 { break }
            try #require(clock.now < deadline, "Relay did not consume the source data")
            usleep(1000)
        }

        let probeCalled = DispatchSemaphore(value: 0)
        try ProcessSupervisor.default.registerFd(probeFD, mask: .input) { _ in probeCalled.signal() }
        try write([1], to: probe.fileHandleForWriting.fileDescriptor)
        #expect(probeCalled.wait(timeout: .now() + 1) == .success)

        if closeExplicitly {
            let closeReturned = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                pair.close()
                closeReturned.signal()
            }
            let result = closeReturned.wait(timeout: .now() + 1)
            #expect(result == .success)
            if result == .success {
                // TerminalIO may release the original handles while the pair finishes draining.
                try source.fileHandleForReading.close()
                try destination.fileHandleForWriting.close()
            }
        } else {
            try source.fileHandleForWriting.close()
        }

        #expect(try read(from: destinationFD) == [UInt8](repeating: 0xAA, count: filled) + payload)
    }

    @Test
    func sharedReadAndWriteDescriptorPreservesUnownedDestination() throws {
        var fds: [Int32] = [0, 0]
        #if canImport(Musl)
        let type = SOCK_STREAM | SOCK_NONBLOCK
        #else
        let type = Int32(SOCK_STREAM.rawValue | SOCK_NONBLOCK.rawValue)
        #endif
        try #require(socketpair(AF_UNIX, type, 0, &fds) == 0)
        let shared = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        let peer = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        let input = Pipe()
        let output = Pipe()
        let stdin = IOPair(readFrom: input.fileHandleForReading, writeTo: UnownedIOCloser(shared), reason: "shared stdin test")
        let stdout = IOPair(readFrom: shared, writeTo: output.fileHandleForWriting, reason: "shared stdout test")
        defer {
            drain(peer.fileDescriptor)
            drain(output.fileHandleForReading.fileDescriptor)
            stdin.close()
            stdout.close()
            try? shared.close()
            try? peer.close()
            for pipe in [input, output] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        try stdin.relay(ignoreHup: true)
        try stdout.relay(ignoreHup: true)

        stdin.close()
        #expect(fcntl(shared.fileDescriptor, F_GETFD) >= 0)

        let response = Array("terminal output after stdin closes".utf8)
        try write(response, to: peer.fileDescriptor)
        try #require(shutdown(peer.fileDescriptor, Int32(SHUT_WR)) == 0)
        #expect(try read(from: output.fileHandleForReading.fileDescriptor) == response)
    }

    @Test
    func terminalHangupReleasesBlockedInput() throws {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        try #require(openpty(&masterFD, &slaveFD, nil, nil, nil) == 0)
        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let path = String(cString: try #require(ttyname(slaveFD)))
        var attributes = termios()
        try #require(tcgetattr(slaveFD, &attributes) == 0)
        cfmakeraw(&attributes)
        try #require(tcsetattr(slaveFD, TCSANOW, &attributes) == 0)
        let source = Pipe()
        let sourceClosed = DispatchSemaphore(value: 0)
        let pair = IOPair(
            readFrom: CloseObserver(handle: source.fileHandleForReading, closed: sourceClosed),
            writeTo: master,
            reason: "terminal hangup test"
        )
        var didClose = false
        defer {
            if !didClose {
                let recoveryFD = Foundation.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
                if recoveryFD >= 0 {
                    _ = tcsetattr(recoveryFD, TCSANOW, &attributes)
                    for _ in 0..<100 {
                        drain(recoveryFD)
                        pair.close()
                        if sourceClosed.wait(timeout: .now() + .milliseconds(10)) == .success { break }
                    }
                    Foundation.close(recoveryFD)
                }
            }
            pair.close()
            try? source.fileHandleForReading.close()
            try? source.fileHandleForWriting.close()
            try? master.close()
            try? slave.close()
        }
        _ = try fill(masterFD)
        try pair.relay(ignoreHup: true)
        let payload = [UInt8](repeating: 0x42, count: 8192)
        try write(payload, to: source.fileHandleForWriting.fileDescriptor)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while true {
            var remaining: Int32 = 0
            try #require(ioctl(source.fileHandleForReading.fileDescriptor, UInt(FIONREAD), &remaining) == 0)
            if remaining < payload.count { break }
            try #require(clock.now < deadline, "Relay did not consume terminal input")
            usleep(1000)
        }
        try slave.close()
        pair.close()
        didClose = sourceClosed.wait(timeout: .now() + 1) == .success
        #expect(didClose)
    }
}

#endif
