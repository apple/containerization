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

import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import Synchronization
import SystemPackage

final class NativeProcess: ContainerProcess, Sendable {
    private struct State {
        init(io: ManagedProcess.IO) {
            self.io = io
        }

        var waiters: [CheckedContinuation<ContainerExitStatus, Never>] = []
        var exitStatus: ContainerExitStatus? = nil
        var pid: Int32?
        let io: ManagedProcess.IO
    }

    let id: String

    private let log: Logger
    private let command: Command
    private let state: Mutex<State>

    var pid: Int32? {
        self.state.withLock {
            $0.pid
        }
    }

    init(
        id: String,
        stdio: HostStdio,
        process: ContainerizationOCI.Process,
        log: Logger
    ) throws {
        self.id = id
        var log = log
        log[metadataKey: "id"] = "\(id)"
        self.log = log

        guard !process.args.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "process args cannot be empty")
        }

        let executableArg = process.args[0]
        guard executableArg.hasPrefix("/") else {
            throw ContainerizationError(.invalidArgument, message: "executable path must be absolute path")
        }

        let executable = FilePath(executableArg)
        guard FileManager.default.fileExists(atPath: executable.string) else {
            throw ContainerizationError(.invalidArgument, message: "failed to find target executable \(executableArg)")
        }

        var command = Command(
            executable.string,
            arguments: Array(process.args.dropFirst()),
            environment: process.env,
            directory: process.cwd
        )

        guard !stdio.terminal else {
            throw ContainerizationError(.invalidArgument, message: "native process doesn't support terminal")
        }

        command.attrs = .init(setsid: false)
        let io = StandardIO(
            stdio: stdio,
            log: log
        )

        log.info("starting I/O")

        // Setup IO early. We expect the host to be listening already.
        try io.start(process: &command)

        self.command = command
        self.state = Mutex(State(io: io))
    }

    func start() async throws -> Int32 {
        do {
            return try self.state.withLock {
                log.info(
                    "starting native process",
                    metadata: ["id": "\(id)"]
                )

                try command.start()
                try $0.io.closeAfterExec()

                let pid = command.pid
                $0.pid = pid

                log.info(
                    "started native process",
                    metadata: [
                        "pid": "\(pid)",
                        "id": "\(id)",
                    ]
                )

                return pid
            }
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "native process failed to start: \(error)"
            )
        }
    }

    func setExit(_ status: Int32) {
        self.state.withLock { state in
            self.log.info(
                "native process exit",
                metadata: [
                    "status": "\(status)"
                ]
            )

            let exitStatus = ContainerExitStatus(exitCode: status, exitedAt: Date.now)
            state.exitStatus = exitStatus

            do {
                try state.io.close()
            } catch {
                self.log.error("failed to close I/O for process: \(error)")
            }

            for waiter in state.waiters {
                waiter.resume(returning: exitStatus)
            }

            self.log.debug("\(state.waiters.count) native process waiters signaled")
            state.waiters.removeAll()
        }
    }

    func wait() async -> ContainerExitStatus {
        await withCheckedContinuation { cont in
            self.state.withLock {
                if let status = $0.exitStatus {
                    cont.resume(returning: status)
                    return
                }
                $0.waiters.append(cont)
            }
        }
    }

    func kill(_ signal: Int32) async throws {
        try self.state.withLock {
            guard let pid = $0.pid else {
                throw ContainerizationError(.invalidState, message: "process PID is required")
            }

            guard $0.exitStatus == nil else {
                return
            }

            self.log.info("sending signal \(signal) to native process \(pid)")
            guard Foundation.kill(pid, signal) == 0 else {
                throw POSIXError.fromErrno()
            }
        }
    }

    func resize(size: Terminal.Size) throws {
        try self.state.withLock {
            guard $0.exitStatus == nil else {
                return
            }
            try $0.io.resize(size: size)
        }
    }

    func closeStdin() throws {
        let io = self.state.withLock { $0.io }
        try io.closeStdin()
    }

    func delete() async throws {
        // Nothing to be done
    }

}
