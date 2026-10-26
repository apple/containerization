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
import Logging
import NIOPosix
import Testing
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

@testable import ContainerizationOS
@testable import VminitdCore

@Suite("Vsock proxy ownership", .serialized)
struct VsockProxyOwnershipTests {
    private struct AcceptanceLogHandler: LogHandler {
        let accepted: DispatchSemaphore
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .debug

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            if event.message.description == "accepting connection" { accepted.signal() }
        }
    }

    private func socketPair() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        #if canImport(Musl)
        let type = SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
        #else
        let type = Int32(SOCK_STREAM.rawValue | SOCK_NONBLOCK.rawValue | SOCK_CLOEXEC.rawValue)
        #endif
        try #require(socketpair(AF_UNIX, type, 0, &descriptors) == 0)
        return descriptors
    }

    private func receive(on peer: Int32) async throws -> UInt8? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while true {
                        try #require(ContinuousClock.now < deadline, "Timed out waiting for relay data or EOF")
                        var event = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
                        let ready = poll(&event, 1, 100)
                        if ready == 0 || (ready == -1 && errno == EINTR) { continue }
                        try #require(ready > 0)
                        var byte: UInt8 = 0
                        let count = Foundation.read(peer, &byte, 1)
                        if count == -1 && (errno == EAGAIN || errno == EINTR) { continue }
                        try #require(count >= 0)
                        continuation.resume(returning: count == 0 ? nil : byte)
                        return
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    @Test
    func alreadyCancelledRelayClosesBothEndpoints() async throws {
        let client = try socketPair()
        let server = try socketPair()
        defer {
            _ = Foundation.close(client[1])
            _ = Foundation.close(server[1])
        }
        let completed = DispatchSemaphore(value: 0)
        let task = Task {
            defer { completed.signal() }
            withUnsafeCurrentTask { $0?.cancel() }
            try await VsockProxy.relay(
                client: DescriptorTransfer(adopting: client[0]),
                server: DescriptorTransfer(adopting: server[0])
            )
        }
        defer { task.cancel() }
        // Cancellation can finish the session before start installs its continuation.
        let didComplete = await waitForSignal(completed)
        try #require(didComplete, "Already-cancelled relay did not complete")
        do {
            try await task.value
            Issue.record("A cancelled relay completed successfully")
        } catch is CancellationError {}
        #expect(try await receive(on: client[1]) == nil)
        #expect(try await receive(on: server[1]) == nil)
    }

    @Test
    func partialRegistrationFailureClosesBothEndpoints() async throws {
        let client = try socketPair()
        defer { _ = Foundation.close(client[1]) }
        // /dev/null fails the second epoll registration with EPERM.
        let regular = Foundation.open("/dev/null", O_RDWR | O_CLOEXEC)
        try #require(regular >= 0)
        let closeAttempts = Mutex(0)
        let closed = DispatchSemaphore(value: 0)
        let owner = OwnedDescriptor(
            adopting: regular,
            closeImplementation: { descriptor in
                closeAttempts.withLock { $0 += 1 }
                defer { closed.signal() }
                return Foundation.close(descriptor)
            })
        defer { try? owner.close() }
        let completed = DispatchSemaphore(value: 0)
        let task = Task {
            defer { completed.signal() }
            try await VsockProxy.relay(
                client: DescriptorTransfer(adopting: client[0]),
                server: DescriptorTransfer(owner: owner)
            )
        }
        defer { task.cancel() }
        let didComplete = await waitForSignal(completed)
        try #require(didComplete, "Partial registration failure did not complete")
        await #expect(throws: POSIXError(.EPERM)) { try await task.value }
        #expect(try await receive(on: client[1]) == nil)
        // Observe rollback while retaining the owner; explicitly closing would mask a leak.
        let didClose = await waitForSignal(closed)
        try #require(didClose, "Partial registration rollback did not close the server endpoint")
        #expect(closeAttempts.withLock { $0 } == 1)
    }

    @Test
    func stopClosesConnectionBeforeQueuedConnectRuns() async throws {
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pool.submit { state in
            guard case .active = state else { return }
            entered.signal()
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        let accepted = DispatchSemaphore(value: 0)
        let path = URL(fileURLWithPath: "/tmp/proxy-\(UUID().uuidString).sock")
        let proxy = VsockProxy(
            id: UUID().uuidString,
            action: .dial,
            port: UInt32.max,
            path: path,
            udsPerms: nil,
            blockingPool: pool,
            log: Logger(label: "queued-connect") { _ in AcceptanceLogHandler(accepted: accepted) }
        )
        do {
            try #require(entered.wait(timeout: .now() + 5) == .success)
            try await proxy.start()
            let client = try Socket(type: UnixType(path: path.path))
            defer { try? client.close() }
            try client.connect()
            try #require(accepted.wait(timeout: .now() + 5) == .success)
            // Reentering the actor proves connection setup has suspended on the occupied pool.
            try await proxy.start()
            var event = pollfd(fd: client.fileDescriptor, events: Int16(POLLIN), revents: 0)
            #expect(poll(&event, 1, 0) == 0)
            try await proxy.close()
            #expect(try await receive(on: client.fileDescriptor) == nil)
        } catch {
            release.signal()
            try? await proxy.close()
            try? await pool.shutdownGracefully()
            throw error
        }
        release.signal()
        try await pool.shutdownGracefully()
    }
}

#endif
