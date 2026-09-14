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

/// An exec process implementation that uses `runc exec` as the OCI runtime.
///
/// The counterpart to `RuncProcess`, which owns the container's init process.
/// Both reuse the same `RuncProcess.IO` implementations; the differences are
/// forced by `runc exec` having no create/start split and no per-exec state.
final class RuncExecProcess: ContainerProcess, Sendable {
    private enum ProcessState {
        case initial
        case starting
        case running(pid: Int32)
        case exited(ContainerExitStatus)
    }

    private struct State {
        var state: ProcessState = .initial
        var waiters: [CheckedContinuation<ContainerExitStatus, Never>] = []

        /// Whether `attachIO()` has run to a conclusion, successful or not.
        ///
        /// `runc exec --detach` returns with the process already running, so a
        /// reap can land while `start()` is between recording the pid and
        /// wiring the relays. Closing I/O that does not exist yet would leave
        /// `attachConsole`'s `IOPair`s relaying from already-closed sockets.
        var ioAttached = false

        /// `setExit` reached the close first and found no relays, so whoever
        /// finishes attaching owes it.
        var closeIOPending = false
    }

    let id: String

    /// Stand-in status for an exit that was reaped and then dropped, used when
    /// `ProcessSupervisor` reports `.lost`. 255, as containerd reports for an
    /// unknowable exit, rather than something in 128+signal territory.
    private static let lostExitStatus: Int32 = 255

    private let log: Logger
    private let containerID: String
    private let runc: Runc
    private let io: RuncProcess.IO
    private let state: Mutex<State>
    private let terminal: Bool
    private let bundle: ContainerizationOCI.Bundle
    private let consoleSocket: ConsoleSocket?

    var pid: Int32? {
        self.state.withLock {
            switch $0.state {
            case .running(let pid):
                return pid
            default:
                return nil
            }
        }
    }

    init(
        id: String,
        containerID: String,
        stdio: HostStdio,
        bundle: ContainerizationOCI.Bundle,
        runc: Runc,
        log: Logger
    ) throws {
        self.id = id
        self.containerID = containerID
        var log = log
        log[metadataKey: "id"] = "\(id)"
        self.log = log
        self.runc = runc
        self.bundle = bundle
        self.terminal = stdio.terminal

        var io: RuncProcess.IO
        var consoleSocket: ConsoleSocket? = nil

        if stdio.terminal {
            log.info("setting up terminal I/O for runc exec")
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

        log.info("starting I/O for runc exec")
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
                    message: "exec \(self.id) already started"
                )
            }
            $0.state = .starting
        }

        // Sentinel the integration suite asserts on: nothing else distinguishes
        // this path from the vmexec one. Keep in sync with RuncTests.swift.
        log.info("starting runc exec process")

        // `Bundle.createExecSpec` already wrote execs/<id>/process.json; the pid
        // file goes in the same directory so `deleteExecSpec` reclaims both.
        let specPath = self.bundle.getExecSpecPath(id: self.id)
        let pidFilePath = specPath.deletingLastPathComponent().appendingPathComponent("runc-pid").path
        let runcIO = self.io.getIO()

        var opts = ExecOpts(
            pidFile: pidFilePath,
            // Without --detach `runc exec` blocks until the process exits, so
            // start() could never return a pid. Same as containerd.
            detach: true,
            processPath: specPath.path,
            io: runcIO
        )
        if let consoleSocket {
            opts.consoleSocket = consoleSocket.path
        }

        // `runc exec` addresses the container, not the exec -- the process to
        // run comes entirely from --process.
        guard
            let pidInt = try await self.runc.exec(
                id: self.containerID,
                opts: opts
            )
        else {
            throw ContainerizationError(
                .internalError,
                message: "runc exec did not return a PID"
            )
        }

        let pid = Int32(pidInt)

        self.state.withLock {
            $0.state = .running(pid: pid)
        }

        self.log.info(
            "runc exec started",
            metadata: [
                "pid": "\(pid)"
            ])

        // `runc exec --detach` returns with the process already running, so it
        // may have been reaped before the pid was published. `ProcessSupervisor`
        // parks such a status; `.lost` means even the parked copy expired and
        // nothing else can ever deliver this exit. Both cases deregister us, so
        // from here on the exit is ours to deliver.
        var claimed: Int32? = nil
        switch ProcessSupervisor.default.claimExit(pid: pid, claimant: self) {
        case .claimed(let status):
            claimed = status
        case .lost:
            // A wrong exit code is recoverable; a `wait()` that never returns is
            // not. Loud, because reaching this means a status was dropped.
            self.log.error(
                "runc exec was reaped with no exit status to claim; synthesizing one",
                metadata: [
                    "pid": "\(pid)",
                    "status": "\(Self.lostExitStatus)",
                ])
            claimed = Self.lostExitStatus
        case .pending:
            break
        }

        if let status = claimed {
            self.log.info(
                "runc exec exited before its pid was recorded",
                metadata: [
                    "pid": "\(pid)",
                    "status": "\(status)",
                ])

            // Wire up I/O as the live path does even though the process is
            // gone: only the IOPairs close the vsock fds, and skipping this
            // drops whatever the exec wrote. `receiveMaster()` does not block --
            // `runc init` hands the pty master over before exec'ing the user
            // process. Errors are logged, not thrown; `setExit` still has to run.
            do {
                try self.attachIOAndSettle()
            } catch {
                self.log.error("failed to attach I/O for an already-exited runc exec: \(error)")
            }

            self.setExit(status)
            return pid
        }

        do {
            try self.attachIOAndSettle()
        } catch {
            // `runc exec --detach` has already returned, so nothing else holds
            // a still-running process: rethrowing alone would orphan it in the
            // container cgroup. `self.pid` is nil once `setExit` has run, which
            // keeps this from signalling an already-reaped (or recycled) pid.
            if let livePid = self.pid {
                self.log.error(
                    "failed to attach I/O to a live runc exec, killing it",
                    metadata: [
                        "pid": "\(livePid)",
                        "error": "\(error)",
                    ])
                if Foundation.kill(livePid, SIGKILL) != 0 {
                    self.log.error("failed to kill orphaned runc exec \(livePid): \(POSIXError.fromErrno())")
                }
            } else {
                self.log.error(
                    "failed to attach I/O to runc exec, which has already exited",
                    metadata: [
                        "pid": "\(pid)",
                        "error": "\(error)",
                    ])
            }

            // Nothing else is guaranteed to close: `setExit` may never run,
            // since `ProcessSupervisor.start` deregisters us on the way out of
            // this throw. Safe unconditionally -- both `RuncProcess.IO`
            // implementations nil their fields under their own mutex.
            self.closeIO()
            throw error
        }

        return pid
    }

    /// Wire up I/O, then settle with `setExit` over which of the two closes it.
    /// The exit can arrive mid-call, so the close cannot simply belong to
    /// `setExit`.
    private func attachIOAndSettle() throws {
        // Runs even when attaching failed: `io.close()` is the only thing that
        // reclaims the vsock sockets.
        defer {
            let closeOwed = self.state.withLock { state -> Bool in
                state.ioAttached = true
                defer { state.closeIOPending = false }
                return state.closeIOPending
            }
            if closeOwed {
                // `IOPair.close()` drains first, so what the pty buffered
                // during attach still reaches the host.
                self.log.debug("closing I/O for a runc exec that exited while its relays were being attached")
                self.closeIO()
            }
        }
        try self.attachIO()
    }

    /// Hand back the ends runc inherited and, for a terminal, take delivery of
    /// the pty master and start relaying it.
    private func attachIO() throws {
        if self.terminal, let consoleSocket = self.consoleSocket {
            self.log.info("waiting for console FD from runc exec")
            let ptyFd = try consoleSocket.receiveMaster()

            self.log.info("received PTY FD from runc exec, attaching")

            try self.io.closeAfterExec()
            try self.io.attachConsole(fd: ptyFd)
        } else {
            try self.io.closeAfterExec()
        }
    }

    func setExit(_ status: Int32) {
        self.state.withLock {
            // First delivery wins. The supervisor's reap and a `start()` claim
            // should not overlap, but a second, different exit reported to
            // waiters who already saw the first would be worse than a no-op.
            if case .exited = $0.state {
                self.log.debug(
                    "ignoring a second exit for a runc exec",
                    metadata: [
                        "status": "\(status)"
                    ])
                return
            }

            self.log.info(
                "runc exec process exit",
                metadata: [
                    "status": "\(status)"
                ])

            let exitStatus = ContainerExitStatus(exitCode: status, exitedAt: Date.now)
            $0.state = .exited(exitStatus)

            // Only close relays that exist. If `start()` is still attaching,
            // closing now would pull the sockets out from under the IOPairs it
            // is about to build; leave the close to it instead.
            if $0.ioAttached {
                self.closeIO()
            } else {
                $0.closeIOPending = true
            }

            for waiter in $0.waiters {
                waiter.resume(returning: exitStatus)
            }

            self.log.debug("\($0.waiters.count) runc exec process waiters signaled")
            $0.waiters.removeAll()
        }
    }

    /// Tear down the I/O relays. Called by whichever of `setExit` and
    /// `attachIOAndSettle` finishes second, and by `start()` when attaching
    /// threw. Redundant calls are harmless: both `RuncProcess.IO`
    /// implementations nil their fields under their own mutex.
    private func closeIO() {
        do {
            try self.io.close()
        } catch {
            self.log.error("failed to close I/O for process: \(error)")
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
        // Signal the pid directly rather than going through `runc kill`, which
        // can only address a container's init process -- runc keeps no state
        // for an exec, so there is no name to pass it.
        try self.state.withLock {
            switch $0.state {
            case .exited:
                return
            case .running(let pid):
                self.log.info("sending signal \(signal) to runc exec process \(pid)")
                guard Foundation.kill(pid, signal) == 0 else {
                    throw POSIXError.fromErrno()
                }
            case .initial, .starting:
                throw ContainerizationError(
                    .invalidState,
                    message: "process PID is required"
                )
            }
        }
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
        // No `runc delete` counterpart: runc holds no per-exec state, so the
        // only thing to reclaim is the console socket. The process spec and pid
        // file live under execs/<id>, which `Bundle.deleteExecSpec` removes.
        if let consoleSocket = self.consoleSocket {
            try consoleSocket.close()
        }
    }
}

#endif
