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

import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import Synchronization

/// A container process implementation that uses runc as the OCI runtime
final class RuncProcess: ContainerProcess, Sendable {
    // swiftlint: disable type_name
    protocol IO: Sendable {
        func attachConsole(fd: Int32) throws
        func create() throws
        func getIO() -> Runc.IO
        func closeAfterExec() throws
        func resize(size: Terminal.Size) throws
        func close() throws
        func closeStdin() throws
    }
    // swiftlint: enable type_name

    private enum ProcessState {
        case initial
        case creating
        /// `runc create` returned and the container init exists, but `runc
        /// start` has not run yet. The pid must be visible to ProcessSupervisor
        /// from here on, or an exit reaped while `pid` is nil is dropped.
        case created(pid: Int32)
        case running(pid: Int32)
        case exited(ContainerExitStatus)
    }

    private struct State {
        var state: ProcessState = .initial
        var waiters: [CheckedContinuation<ContainerExitStatus, Never>] = []
    }

    let id: String

    private let log: Logger
    private let runc: Runc
    private let io: IO
    private let state: Mutex<State>
    private let terminal: Bool
    private let bundle: ContainerizationOCI.Bundle
    private let consoleSocket: ConsoleSocket?

    var pid: Int32? {
        self.state.withLock {
            switch $0.state {
            case .created(let pid), .running(let pid):
                return pid
            default:
                return nil
            }
        }
    }

    init(
        id: String,
        stdio: HostStdio,
        bundle: ContainerizationOCI.Bundle,
        runc: Runc,
        log: Logger
    ) throws {
        self.id = id
        var log = log
        log[metadataKey: "id"] = "\(id)"
        self.log = log
        self.runc = runc
        self.bundle = bundle
        self.terminal = stdio.terminal

        var io: IO
        var consoleSocket: ConsoleSocket? = nil

        if stdio.terminal {
            log.info("setting up terminal I/O for runc")
            let socket = try ConsoleSocket.temporary()
            consoleSocket = socket
            io = try RuncTerminalIO(
                stdio: stdio,
                log: log
            )
        } else {
            io = RuncStandardIO(
                stdio: stdio,
                log: log
            )
        }

        log.info("starting I/O for runc")
        try io.create()

        self.consoleSocket = consoleSocket
        self.io = io
        self.state = Mutex(State())
    }

    func start() async throws -> Int32 {
        try self.state.withLock {
            guard case .initial = $0.state else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container already started"
                )
            }
            $0.state = .creating
        }

        log.info(
            "starting runc process",
            metadata: [
                "id": "\(id)"
            ])

        let pidFilePath = self.bundle.path.appendingPathComponent("runc-pid").path
        let runcIO = self.io.getIO()

        let opts: CreateOpts
        if let consoleSocket {
            opts = CreateOpts(
                pidFile: pidFilePath,
                consoleSocket: consoleSocket.path,
                io: runcIO
            )
        } else {
            opts = CreateOpts(
                pidFile: pidFilePath,
                io: runcIO
            )
        }

        guard
            let pidInt = try await self.runc.create(
                id: self.id,
                bundle: self.bundle.path.path,
                opts: opts
            )
        else {
            throw ContainerizationError(
                .internalError,
                message: "runc create did not return a PID"
            )
        }

        let pid = Int32(pidInt)

        // Publish the pid before `runc start`. The container init is parked in
        // runc's start-wait right now, so it provably cannot have exited yet —
        // this closes the reap race rather than narrowing it.
        self.state.withLock {
            $0.state = .created(pid: pid)
        }

        self.log.info(
            "container created",
            metadata: [
                "pid": "\(pid)"
            ])

        // Close the pipe ends we gave to runc now that it has inherited them
        // and attach console if in terminal mode
        if self.terminal, let consoleSocket = self.consoleSocket {
            self.log.info("waiting for console FD from runc")
            let ptyFd = try consoleSocket.receiveMaster()

            self.log.info(
                "received PTY FD from runc, attaching",
                metadata: [
                    "id": "\(self.id)"
                ])

            try self.io.closeAfterExec()
            try self.io.attachConsole(fd: ptyFd)
        } else {
            try self.io.closeAfterExec()
        }

        try await self.runc.start(id: self.id)

        self.state.withLock {
            // The process may already have run to completion and been reaped
            // between `runc start` and here; `setExit` owns the terminal state.
            if case .exited = $0.state {
                return
            }
            $0.state = .running(pid: pid)
        }

        self.log.info(
            "started runc process",
            metadata: [
                "pid": "\(pid)",
                "id": "\(self.id)",
            ])

        return pid
    }

    func setExit(_ status: Int32) {
        self.state.withLock {
            self.log.info(
                "runc process exit",
                metadata: [
                    "status": "\(status)"
                ])

            let exitStatus = ContainerExitStatus(exitCode: status, exitedAt: Date.now)
            $0.state = .exited(exitStatus)

            do {
                try self.io.close()
            } catch {
                self.log.error("failed to close I/O for process: \(error)")
            }

            for waiter in $0.waiters {
                waiter.resume(returning: exitStatus)
            }

            self.log.debug("\($0.waiters.count) runc process waiters signaled")
            $0.waiters.removeAll()
        }
    }

    func wait() async -> ContainerExitStatus {
        await withCheckedContinuation { cont in
            self.state.withLock {
                if case .exited(let exitStatus) = $0.state {
                    cont.resume(returning: exitStatus)
                    return
                }
                $0.waiters.append(cont)
            }
        }
    }

    func kill(_ signal: Int32) async throws {
        self.log.info("sending signal \(signal) to runc container \(id)")
        try await self.runc.kill(id: self.id, signal: signal)
    }

    func resize(size: Terminal.Size) throws {
        try self.state.withLock {
            if case .exited = $0.state {
                return
            }
            try self.io.resize(size: size)
        }
    }

    func closeStdin() throws {
        try self.io.closeStdin()
    }

    func delete() async throws {
        let shouldDelete = self.state.withLock { state -> Bool in
            switch state.state {
            case .initial, .creating:
                return false
            default:
                return true
            }
        }

        guard shouldDelete else {
            log.info("container was never created, skipping delete")
            return
        }

        log.info("deleting runc container", metadata: ["id": "\(id)"])

        try await self.runc.delete(
            id: self.id,
            opts: DeleteOpts(force: true)
        )

        if let consoleSocket = self.consoleSocket {
            try consoleSocket.close()
        }
    }
}

#endif
