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

#if os(Linux)

import Containerization
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
            case .running(let pid):
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

// MARK: - RuncTerminalIO

final class RuncTerminalIO: RuncProcess.IO & Sendable {
    private struct State {
        var stdinSocket: Socket?
        var stdoutSocket: Socket?

        var stdin: IOPair?
        var stdout: IOPair?
        var terminal: Terminal?
    }

    private let log: Logger?
    private let hostStdio: HostStdio
    private let state: Mutex<State>

    init(
        stdio: HostStdio,
        log: Logger?
    ) throws {
        self.hostStdio = stdio
        self.log = log
        self.state = Mutex(State())
    }

    func resize(size: Terminal.Size) throws {
        try self.state.withLock {
            if let terminal = $0.terminal {
                try terminal.resize(size: size)
            }
        }
    }

    func create() throws {
        try self.state.withLock {
            if let stdinPort = self.hostStdio.stdin {
                let type = VsockType(
                    port: stdinPort,
                    cid: VsockType.hostCID
                )
                let stdinSocket = try Socket(type: type, closeOnDeinit: false)
                try stdinSocket.connect()
                $0.stdinSocket = stdinSocket
            }

            if let stdoutPort = self.hostStdio.stdout {
                let type = VsockType(
                    port: stdoutPort,
                    cid: VsockType.hostCID
                )
                let stdoutSocket = try Socket(type: type, closeOnDeinit: false)
                try stdoutSocket.connect()
                $0.stdoutSocket = stdoutSocket
            }
        }
    }

    func getIO() -> Runc.IO {
        // Terminal mode doesn't pass pipes to runc, it uses the console socket
        .inherit
    }

    func closeAfterExec() throws {
        // No pipes to close in terminal mode
    }

    func attachConsole(fd: Int32) throws {
        try self.state.withLock {
            let term = try Terminal(descriptor: fd, setInitState: false)
            $0.terminal = term

            if let stdinSocket = $0.stdinSocket {
                let pair = IOPair(
                    readFrom: stdinSocket,
                    writeTo: term,
                    reason: "RuncTerminalIO stdin",
                    logger: log
                )
                try pair.relay(ignoreHup: true)
                $0.stdin = pair
            }

            if let stdoutSocket = $0.stdoutSocket {
                let pair = IOPair(
                    readFrom: term,
                    writeTo: stdoutSocket,
                    reason: "RuncTerminalIO stdout",
                    logger: log
                )
                try pair.relay(ignoreHup: true)
                $0.stdout = pair
            }
        }
    }

    func close() throws {
        self.state.withLock {
            if let stdin = $0.stdin {
                stdin.close()
                $0.stdin = nil
            }
            if let stdout = $0.stdout {
                stdout.close()
                $0.stdout = nil
            }
            $0.terminal = nil
        }
    }

    func closeStdin() throws {
        self.state.withLock {
            if let stdin = $0.stdin {
                stdin.close()
                $0.stdin = nil
            }
        }
    }
}

// MARK: - RuncStandardIO

final class RuncStandardIO: RuncProcess.IO & Sendable {
    private struct State {
        var stdin: IOPair?
        var stdout: IOPair?
        var stderr: IOPair?

        var stdinPipe: Pipe?
        var stdoutPipe: Pipe?
        var stderrPipe: Pipe?
    }

    private let log: Logger?
    private let hostStdio: HostStdio
    private let state: Mutex<State>

    init(
        stdio: HostStdio,
        log: Logger?
    ) {
        self.hostStdio = stdio
        self.log = log
        self.state = Mutex(State())
    }

    // NOP for non-terminal
    func attachConsole(fd: Int32) throws {}

    func create() throws {
        try self.state.withLock {
            if let stdinPort = self.hostStdio.stdin {
                let inPipe = Pipe()
                $0.stdinPipe = inPipe

                let type = VsockType(
                    port: stdinPort,
                    cid: VsockType.hostCID
                )
                let stdinSocket = try Socket(type: type, closeOnDeinit: false)
                try stdinSocket.connect()

                let pair = IOPair(
                    readFrom: stdinSocket,
                    writeTo: inPipe.fileHandleForWriting,
                    reason: "RuncStandardIO stdin",
                    logger: log
                )
                $0.stdin = pair
                try pair.relay()
            }

            if let stdoutPort = self.hostStdio.stdout {
                let outPipe = Pipe()
                $0.stdoutPipe = outPipe

                let type = VsockType(
                    port: stdoutPort,
                    cid: VsockType.hostCID
                )
                let stdoutSocket = try Socket(type: type, closeOnDeinit: false)
                try stdoutSocket.connect()

                let pair = IOPair(
                    readFrom: outPipe.fileHandleForReading,
                    writeTo: stdoutSocket,
                    reason: "RuncStandardIO stdout",
                    logger: log
                )
                $0.stdout = pair
                try pair.relay()
            }

            if let stderrPort = self.hostStdio.stderr {
                let errPipe = Pipe()
                $0.stderrPipe = errPipe

                let type = VsockType(
                    port: stderrPort,
                    cid: VsockType.hostCID
                )
                let stderrSocket = try Socket(type: type, closeOnDeinit: false)
                try stderrSocket.connect()

                let pair = IOPair(
                    readFrom: errPipe.fileHandleForReading,
                    writeTo: stderrSocket,
                    reason: "RuncStandardIO stderr",
                    logger: log
                )
                $0.stderr = pair
                try pair.relay()
            }
        }
    }

    func getIO() -> Runc.IO {
        self.state.withLock {
            Runc.IO(
                stdin: $0.stdinPipe?.fileHandleForReading,
                stdout: $0.stdoutPipe?.fileHandleForWriting,
                stderr: $0.stderrPipe?.fileHandleForWriting
            )
        }
    }

    func closeAfterExec() throws {
        try self.state.withLock {
            // Close the pipe ends we gave to runc (the child inherited them)
            if let stdinPipe = $0.stdinPipe {
                try stdinPipe.fileHandleForReading.close()
                $0.stdinPipe = nil
            }
            if let stdoutPipe = $0.stdoutPipe {
                try stdoutPipe.fileHandleForWriting.close()
                $0.stdoutPipe = nil
            }
            if let stderrPipe = $0.stderrPipe {
                try stderrPipe.fileHandleForWriting.close()
                $0.stderrPipe = nil
            }
        }
    }

    func resize(size: Terminal.Size) throws {
        throw ContainerizationError(.unsupported, message: "resize not supported for standard IO")
    }

    func close() throws {
        self.state.withLock {
            if let stdin = $0.stdin {
                stdin.close()
                $0.stdin = nil
            }

            if let stdout = $0.stdout {
                stdout.close()
                $0.stdout = nil
            }

            if let stderr = $0.stderr {
                stderr.close()
                $0.stderr = nil
            }
        }
    }

    func closeStdin() throws {
        self.state.withLock {
            if let stdin = $0.stdin {
                stdin.close()
                $0.stdin = nil
            }
        }
    }
}

#endif  // os(Linux)
