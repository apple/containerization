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

import ContainerizationOS
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("Command waitAsync tests")
final class CommandWaitAsyncTests {
    /// Parks `waitAsync` on far more children than there are CPUs; the Swift
    /// cooperative pool must keep scheduling. The blocking `wait4` variant
    /// held a pool thread per child and starved it.
    @Test func poolStaysResponsiveWithManyWaiters() async throws {
        let childCount = max(50, 4 * ProcessInfo.processInfo.processorCount)
        var commands: [Command] = []
        var waits: [Task<Int32, any Error>] = []
        for _ in 0..<childCount {
            let command = Command("/bin/sleep", arguments: ["600"])
            try command.start()
            commands.append(command)
            waits.append(Task { try await command.waitAsync() })
        }
        defer {
            for command in commands {
                _ = command.kill(SIGKILL)
            }
        }

        let start = ContinuousClock.now
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(ContinuousClock.now - start < .seconds(10))

        for command in commands {
            _ = command.kill(SIGKILL)
        }
        for wait in waits {
            #expect(try await wait.value == 128 + Int32(SIGKILL))
        }
    }

    @Test func returnsExitStatus() async throws {
        let command = Command("/bin/sh", arguments: ["-c", "exit 42"])
        try command.start()
        #expect(try await command.waitAsync() == 42)
    }
}
