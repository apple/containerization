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
import Synchronization
import Testing

@testable import Containerization

struct CHVsockTests {
    private func waitUntilReadable(_ fd: Int32) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            try #require(ContinuousClock.now < deadline, "socket did not become readable")
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 0)
            if ready < 0 && errno == EINTR { continue }
            try #require(ready >= 0)
            if ready > 0 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationClosesSilentHandshake() async throws {
        let path = URL(filePath: "/tmp/ch-dial-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: path) }
        let server = try Socket(type: UnixType(path: path.path))
        defer { try? server.close() }
        try server.listen()
        try server.setTimeout(option: .receive, seconds: 5)

        let completed = Mutex(false)
        let dial = Task {
            defer { completed.withLock { $0 = true } }
            do {
                let connection = try await chVsockDialOwned(baseSocket: path, port: 1024)
                try? connection.takeOwner().close()
                return false
            } catch {
                return true
            }
        }
        defer { dial.cancel() }

        try await waitUntilReadable(server.fileDescriptor)
        let peer = try server.accept()
        defer { try? peer.close() }
        try peer.setTimeout(option: .receive, seconds: 5)
        let expected = Data("CONNECT 1024\n".utf8)
        var request = Data()
        while request.count < expected.count {
            try await waitUntilReadable(peer.fileDescriptor)
            var buffer = Data(count: expected.count - request.count)
            let count = try peer.read(buffer: &buffer)
            request.append(buffer.prefix(count))
        }
        #expect(request == expected)

        // Withhold the reply: cancellation must wake the handshake's socket wait.
        dial.cancel()
        try await waitUntilReadable(peer.fileDescriptor)
        var byte = Data(count: 1)
        #expect(throws: SocketError.closed) { _ = try peer.read(buffer: &byte) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !completed.withLock({ $0 }) {
            try #require(ContinuousClock.now < deadline, "cancelled handshake did not finish")
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await dial.value)
    }
}
#endif
