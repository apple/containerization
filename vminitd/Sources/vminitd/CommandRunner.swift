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

import ContainerizationOS
import Foundation
import Synchronization

struct ProcessSubscription: Sendable {
    fileprivate let id: UUID
}

/// Protocol for running commands and waiting for their exit
protocol CommandRunner: Sendable {
    func start(_ cmd: inout Command) throws -> ProcessSubscription
    func wait(_ cmd: Command, subscription: ProcessSubscription) async throws -> Int32
}

struct DirectCommandRunner: CommandRunner {
    func start(_ cmd: inout Command) throws -> ProcessSubscription {
        try cmd.start()
        return ProcessSubscription(id: UUID())
    }

    func wait(_ cmd: Command, subscription: ProcessSubscription) async throws -> Int32 {
        var rus = rusage()
        var ws = Int32()

        let result = wait4(cmd.pid, &ws, 0, &rus)
        guard result == cmd.pid else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        return Command.toExitStatus(ws)
    }
}

final class ReaperCommandRunner: CommandRunner, Sendable {
    private struct Subscriber {
        let continuation: AsyncStream<(pid: pid_t, status: Int32)>.Continuation
        let stream: AsyncStream<(pid: pid_t, status: Int32)>
    }

    private let subscribers: Mutex<[UUID: Subscriber]> = Mutex([:])

    func start(_ cmd: inout Command) throws -> ProcessSubscription {
        // Subscribe before starting to avoid missing fast exits
        let id = UUID()
        let (stream, continuation) = AsyncStream<(pid: pid_t, status: Int32)>.makeStream()

        subscribers.withLock { subscribers in
            subscribers[id] = Subscriber(continuation: continuation, stream: stream)
        }

        try cmd.start()

        return ProcessSubscription(id: id)
    }

    func wait(_ cmd: Command, subscription: ProcessSubscription) async throws -> Int32 {
        let pid = cmd.pid
        let id = subscription.id

        defer {
            subscribers.withLock { subscribers in
                subscribers[id]?.continuation.finish()
                subscribers.removeValue(forKey: id)
            }
        }

        // Get the stream from the subscriber
        guard let stream = subscribers.withLock({ $0[id]?.stream }) else {
            throw POSIXError(.ECHILD)
        }

        for await (exitPid, status) in stream {
            if exitPid == pid {
                return status
            }
        }

        throw POSIXError(.ECHILD)
    }

    /// Broadcast exit to all subscribers
    func notifyExit(pid: pid_t, status: Int32) {
        subscribers.withLock { subscribers in
            for subscriber in subscribers.values {
                subscriber.continuation.yield((pid, status))
            }
        }
    }
}
