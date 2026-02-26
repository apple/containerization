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

import ArgumentParser
import ContainerizationOS
import LCShim
import Musl

/// A minimal init process that:
/// - Spawns and monitors a child process
/// - Forwards signals to the child
/// - Reaps zombie processes
/// - Exits with the child's exit code
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Run as a minimal init process"
    )

    @Flag(name: .shortAndLong, help: "Send signals to the child's process group instead of just the child")
    var processGroup: Bool = false

    @Argument(help: "The command to run")
    var command: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments for the command")
    var arguments: [String] = []

    /// Signals that should NOT be forwarded to the child.
    private static let ignoredSignals: Set<Int32> = [
        SIGCHLD,  // We handle this for zombie reaping
        SIGFPE, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGTRAP, SIGSYS,  // Synchronous signals
    ]

    mutating func run() throws {
        // If we're not PID 1, register as a child subreaper so orphaned
        // processes get reparented to us and we can reap them.
        if getpid() != 1 {
            CZ_set_sub_reaper()
        }

        // Block all signals. We'll handle them synchronously via sigtimedwait
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        sigprocmask(SIG_BLOCK, &allSignals, nil)

        let resolvedCommand = Path.lookPath(command)?.path ?? command

        var cmd = Command(resolvedCommand, arguments: arguments)
        cmd.stdin = .standardInput
        cmd.stdout = .standardOutput
        cmd.stderr = .standardError

        cmd.attrs = .init(setPGroup: true, setForegroundPGroup: true, setSignalDefault: true)

        try cmd.start()
        let childPid = cmd.pid
        let signalTarget = processGroup ? -childPid : childPid
        var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000)

        // Handle signals and reap zombies
        var childExitStatus: Int32?
        while childExitStatus == nil {
            var siginfo = siginfo_t()
            let sig = sigtimedwait(&allSignals, &siginfo, &timeout)

            if sig > 0 && !Self.ignoredSignals.contains(sig) {
                _ = Musl.kill(signalTarget, sig)
            }

            while true {
                var status: Int32 = 0
                let pid = waitpid(-1, &status, WNOHANG)
                if pid <= 0 {
                    break
                }
                if pid == childPid {
                    childExitStatus = Command.toExitStatus(status)
                }
            }
        }

        Musl.exit(childExitStatus ?? 1)
    }
}
