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
import NIO
import Synchronization
import Testing

@testable import Containerization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `Vminitd.close()` must return when it races `runConnections()`, and releasing the
/// value must stay in-process. `beginGracefulShutdown()` before the transport consumes
/// the channel skips `connect()`, so the preconfigured writer is never finished and the
/// host dies with SIGTRAP. An unread socketpair reproduces that with no guest.
@Suite struct VminitdCloseTests {
    private struct ShutdownTimedOut: Error {}

    @Test(.timeLimit(.minutes(1)))
    func closeImmediatelyAfterInitDoesNotTrap() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for _ in 0..<40 {
                try await withUnreadPeer(group) { agent in
                    try await agent.close()
                }
            }
            // runConnections() has entered the transport, which can already be .running while
            // the wrapped channel is still idle or configuring.
            try await withUnreadPeer(group) { agent in
                for _ in 0..<5 {
                    await Task.yield()
                }
                try await agent.close()
            }
            // A second close on the same value returns; releasing it still must not trap.
            try await withUnreadPeer(group) { agent in
                try await agent.close()
                try await agent.close()
            }
        } catch {
            await shutdown(group)
            throw error
        }
        await shutdown(group)
    }

    /// The peer stays open until `agent` is released. `withConnectedSocket` owns the
    /// descriptor passed to `init`, so only the unread peer is closed here.
    private func withUnreadPeer(
        _ group: any EventLoopGroup,
        _ body: (Vminitd) async throws -> Void
    ) async throws {
        let (connection, peer) = try socketPair()
        defer { try? peer.close() }
        do {
            let agent = try await Vminitd(connection: connection, group: group)
            try await body(agent)
        }
    }

    private func socketPair() throws -> (connection: FileHandle, peer: FileHandle) {
        var fds: [Int32] = [-1, -1]
        #if canImport(Glibc)
        let type = Int32(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        try #require(socketpair(AF_UNIX, type, 0, &fds) == 0)
        return (
            FileHandle(fileDescriptor: fds[0], closeOnDealloc: false),
            FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        )
    }

    /// Use callbacks so the watchdog can return even though shutdown ignores task cancellation.
    private func shutdown(_ group: MultiThreadedEventLoopGroup) async {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let pending = Mutex<CheckedContinuation<Void, any Error>?>(continuation)
                let complete: @Sendable (Error?) -> Void = { error in
                    let continuation = pending.withLock { pending in
                        defer { pending = nil }
                        return pending
                    }
                    guard let continuation else { return }
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5)) {
                    complete(ShutdownTimedOut())
                }
                group.shutdownGracefully(queue: .global()) { [group] error in
                    // Keep ownership of the group even if the watchdog has already returned.
                    withExtendedLifetime(group) {
                        complete(error)
                    }
                }
            }
        } catch {
            Issue.record("event loop group \(ObjectIdentifier(group)) did not shut down: \(error)")
        }
    }
}
