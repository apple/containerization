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

@Suite("OSFile splice tests")
struct OSFileSpliceTests {
    private func socketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        #if canImport(Musl)
        let type = SOCK_STREAM | SOCK_NONBLOCK
        #else
        let type = Int32(SOCK_STREAM.rawValue | SOCK_NONBLOCK.rawValue)
        #endif
        try #require(socketpair(AF_UNIX, type, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    private func fillSendBuffer(_ fd: Int32) throws -> Int {
        var size: Int32 = 4096
        try #require(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0)
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

    private func write(_ bytes: [UInt8], to fd: Int32) throws {
        let count = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        try #require(count == bytes.count)
    }

    private func readAvailable(_ fd: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4096)
        var result: [UInt8] = []
        while true {
            let count = bytes.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, $0.count) }
            if count == -1 {
                try #require(errno == EAGAIN)
                return result
            }
            if count == 0 {
                return result
            }
            result.append(contentsOf: bytes.prefix(count))
        }
    }

    @Test
    func backpressurePreservesBidirectionalDataBeforeEOF() throws {
        let (clientPeer, clientFD) = try socketPair()
        defer {
            close(clientPeer)
            close(clientFD)
        }
        let (serverFD, serverPeer) = try socketPair()
        defer {
            close(serverFD)
            close(serverPeer)
        }
        var client = OSFile.SpliceFile(fd: clientFD)
        var server = OSFile.SpliceFile(fd: serverFD)
        let buffered = try fillSendBuffer(serverFD)
        let request = Array("pending request".utf8)
        try write(request, to: clientPeer)

        let blocked: (read: Int, wrote: Int, action: OSFile.IOAction)
        do {
            let returned = DispatchSemaphore(value: 0)
            let recovery = DispatchWorkItem {
                guard returned.wait(timeout: .now() + 5) == .timedOut else { return }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while Foundation.read(serverPeer, &bytes, bytes.count) > 0 {}
            }
            DispatchQueue.global().async(execute: recovery)
            defer {
                returned.signal()
                recovery.wait()
            }
            blocked = try OSFile.splice(from: &client, to: &server)
        }
        #expect(blocked.read == request.count)
        #expect(blocked.wrote == 0)
        #expect(blocked.action == .again)

        let reply = Array("reply while request is pending".utf8)
        try write(reply, to: serverPeer)
        let reverse = try OSFile.splice(from: &server, to: &client)
        #expect(reverse.action == .again)
        #expect(try readAvailable(clientPeer) == reply)

        try #require(shutdown(clientPeer, Int32(SHUT_WR)) == 0)
        let stillBlocked = try OSFile.splice(from: &client, to: &server)
        #expect(stillBlocked.action == .again)
        #expect(try readAvailable(serverPeer) == [UInt8](repeating: 0xAA, count: buffered))

        let resumed = try OSFile.splice(from: &client, to: &server)
        #expect(resumed.action == .eof)
        #expect(try readAvailable(serverPeer) == request)
    }
}

#endif
