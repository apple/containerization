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
import ContainerizationOS
import Foundation
import Logging
import Synchronization

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
                    // Unowned: the stdout pair shares this fd, so closing stdin
                    // must not close the pty.
                    writeTo: UnownedIOCloser(term),
                    reason: "RuncTerminalIO stdin",
                    logger: log
                )
                try pair.relay(ignoreHup: true)
                $0.stdin = pair
                // Ownership moves to the pair: `IOPair.close()` closes both of
                // its ends, and clearing the field tells `close()` so.
                $0.stdinSocket = nil
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
                $0.stdoutSocket = nil
            }
        }
    }

    func close() throws {
        self.state.withLock {
            // stdout first: both pairs share the pty fd, and stdout must
            // unregister it from epoll before stdin's close invalidates it.
            if let stdout = $0.stdout {
                stdout.close()
                $0.stdout = nil
            }
            if let stdin = $0.stdin {
                stdin.close()
                $0.stdin = nil
            }

            // Anything still here was never adopted by an IOPair. `create()`
            // connects these with `closeOnDeinit: false`, so not closing them
            // leaks the vsock fds and the host never sees EOF.
            $0.stdinSocket = Self.closeUnadopted($0.stdinSocket, reason: "stdin", log: self.log)
            $0.stdoutSocket = Self.closeUnadopted($0.stdoutSocket, reason: "stdout", log: self.log)

            $0.terminal = nil
        }
    }

    private static func closeUnadopted(_ socket: Socket?, reason: String, log: Logger?) -> Socket? {
        guard let socket else {
            return nil
        }
        do {
            try socket.close()
        } catch {
            log?.error("failed to close unattached \(reason) socket: \(error)")
        }
        return nil
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

#endif
