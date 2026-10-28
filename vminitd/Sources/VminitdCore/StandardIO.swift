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

final class StandardIO: ManagedProcess.IO & Sendable {
    private struct State {
        var stdin: IOPair?
        var stdout: IOPair?
        var stderr: IOPair?

        var stdinPipe: Pipe?
        var stdoutPipe: Pipe?
        var stderrPipe: Pipe?

        // The read ends of the process's output pipes. The relays borrow them (see
        // `UnownedIOCloser`), so a relay ending because its socket went away does not
        // close the pipe under a process that is still running. `close()` does.
        var stdoutReader: FileHandle?
        var stderrReader: FileHandle?

        // The write end of the stdin pipe. The relay only borrows it (see `UnownedIOCloser`),
        // so a relay ending because its socket went away does not give the process an EOF.
        // `closeStdin()` and `close()` do. The relay keeps its own duplicate of the descriptor
        // until it has flushed, so closing this one first does not cut off buffered input.
        var stdinWriter: FileHandle?

        // What `detach()` took out of the relays and could not deliver, oldest first. The process
        // side of each relay is untouched, so these are written first when the relays come back.
        var stdinPending = Data()
        var stdoutPending = Data()
        var stderrPending = Data()
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

    // NOP
    func attach(pid: Int32, fd: Int32) throws {}

    func start(process: inout Command) throws {
        try self.state.withLock {
            if let stdinPort = self.hostStdio.stdin {
                let inPipe = Pipe()
                process.stdin = inPipe.fileHandleForReading
                $0.stdinPipe = inPipe

                let type = VsockType(
                    port: stdinPort,
                    cid: VsockType.hostCID
                )
                let stdinSocket = try Socket(type: type, closeOnDeinit: false)
                try stdinSocket.connect()

                $0.stdinWriter = inPipe.fileHandleForWriting

                let pair = IOPair(
                    readFrom: stdinSocket,
                    writeTo: UnownedIOCloser(inPipe.fileHandleForWriting),
                    reason: "StandardIO stdin",
                    logger: log
                )
                $0.stdin = pair

                try pair.relay()
            }

            if let stdoutPort = self.hostStdio.stdout {
                let outPipe = Pipe()
                process.stdout = outPipe.fileHandleForWriting
                $0.stdoutPipe = outPipe

                let type = VsockType(
                    port: stdoutPort,
                    cid: VsockType.hostCID
                )
                let stdoutSocket = try Socket(type: type, closeOnDeinit: false)
                try stdoutSocket.connect()

                $0.stdoutReader = outPipe.fileHandleForReading

                let pair = IOPair(
                    readFrom: UnownedIOCloser(outPipe.fileHandleForReading),
                    writeTo: stdoutSocket,
                    reason: "StandardIO stdout",
                    logger: log
                )
                $0.stdout = pair

                try pair.relay()
            }

            if let stderrPort = self.hostStdio.stderr {
                let errPipe = Pipe()
                process.stderr = errPipe.fileHandleForWriting
                $0.stderrPipe = errPipe

                let type = VsockType(
                    port: stderrPort,
                    cid: VsockType.hostCID
                )
                let stderrSocket = try Socket(type: type, closeOnDeinit: false)
                try stderrSocket.connect()

                $0.stderrReader = errPipe.fileHandleForReading

                let pair = IOPair(
                    readFrom: UnownedIOCloser(errPipe.fileHandleForReading),
                    writeTo: stderrSocket,
                    reason: "StandardIO stderr",
                    logger: log
                )
                $0.stderr = pair

                try pair.relay()
            }
        }
    }

    func resize(size: Terminal.Size) throws {
        throw ContainerizationError(.unsupported, message: "resize not supported")
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

            // The process is gone, so there is nobody left to give EOF to.
            try? $0.stdinWriter?.close()
            $0.stdinWriter = nil

            // The relays only borrowed these. The process is done with its output now.
            try? $0.stdoutReader?.close()
            $0.stdoutReader = nil
            try? $0.stderrReader?.close()
            $0.stderrReader = nil
        }
    }

    /// Take the relays to the host down without disturbing the process, so the virtual machine
    /// can be paused. The process keeps its pipe ends: output it writes waits in the pipe and
    /// input waits in `stdinPending`, and the process blocks only if it fills a pipe.
    ///
    /// The host must have closed (or half-closed) its stdin socket before this, so that all of
    /// stdin can be read to EOF. It must keep reading stdout and stderr until it sees EOF: each
    /// relay closes its own socket here, after which nothing more arrives on it.
    ///
    /// stdin is detached first because it is the one that can fail. If it throws, nothing has
    /// changed, and the relays carry on as before.
    func detach() throws {
        try self.state.withLock {
            if let stdin = $0.stdin {
                $0.stdinPending = try stdin.detach(readUntilEOF: true)
                $0.stdin = nil
            }
            if let stdout = $0.stdout {
                $0.stdoutPending = try stdout.detach(readUntilEOF: false)
                $0.stdout = nil
            }
            if let stderr = $0.stderr {
                $0.stderrPending = try stderr.detach(readUntilEOF: false)
                $0.stderr = nil
            }
        }
    }

    /// Connect new relays to the host for a process whose relays were taken down by `detach()`.
    ///
    /// `stdio` names the new vsock ports the host is listening on. Each relay is built over the
    /// process's own pipe end, which `detach()` left open, and writes what `detach()` could not
    /// deliver before it carries anything new. The streams in `stdio` must be the ones the
    /// process was started with.
    ///
    /// If this throws, nothing is attached and the pending bytes are kept, except when a relay
    /// fails after others started: those are closed and their pending bytes are lost.
    func reattach(stdio: HostStdio) throws {
        try self.state.withLock {
            guard $0.stdin == nil, $0.stdout == nil, $0.stderr == nil else {
                throw ContainerizationError(.invalidState, message: "stdio is already attached")
            }
            if stdio.stdin != nil && $0.stdinWriter == nil {
                throw ContainerizationError(.invalidState, message: "process has no stdin to attach")
            }
            if stdio.stdout != nil && $0.stdoutReader == nil {
                throw ContainerizationError(.invalidState, message: "process has no stdout to attach")
            }
            if stdio.stderr != nil && $0.stderrReader == nil {
                throw ContainerizationError(.invalidState, message: "process has no stderr to attach")
            }

            var sockets: [Socket] = []
            var started: [IOPair] = []
            do {
                // Everything that can fail on the host's side first, before any relay moves bytes.
                var stdinSocket: Socket?
                var stdoutSocket: Socket?
                var stderrSocket: Socket?
                if let port = stdio.stdin {
                    stdinSocket = try Self.connectToHost(port: port)
                    sockets.append(stdinSocket!)
                }
                if let port = stdio.stdout {
                    stdoutSocket = try Self.connectToHost(port: port)
                    sockets.append(stdoutSocket!)
                }
                if let port = stdio.stderr {
                    stderrSocket = try Self.connectToHost(port: port)
                    sockets.append(stderrSocket!)
                }

                var stdin: IOPair?
                var stdout: IOPair?
                var stderr: IOPair?
                if let socket = stdinSocket, let writer = $0.stdinWriter {
                    let pair = IOPair(
                        readFrom: socket,
                        writeTo: UnownedIOCloser(writer),
                        reason: "StandardIO stdin",
                        pending: $0.stdinPending,
                        logger: log
                    )
                    started.append(pair)
                    try pair.relay()
                    stdin = pair
                }
                if let socket = stdoutSocket, let reader = $0.stdoutReader {
                    let pair = IOPair(
                        readFrom: UnownedIOCloser(reader),
                        writeTo: socket,
                        reason: "StandardIO stdout",
                        pending: $0.stdoutPending,
                        logger: log
                    )
                    started.append(pair)
                    try pair.relay()
                    stdout = pair
                }
                if let socket = stderrSocket, let reader = $0.stderrReader {
                    let pair = IOPair(
                        readFrom: UnownedIOCloser(reader),
                        writeTo: socket,
                        reason: "StandardIO stderr",
                        pending: $0.stderrPending,
                        logger: log
                    )
                    started.append(pair)
                    try pair.relay()
                    stderr = pair
                }

                $0.stdin = stdin
                $0.stdout = stdout
                $0.stderr = stderr
                $0.stdinPending = Data()
                $0.stdoutPending = Data()
                $0.stderrPending = Data()
            } catch {
                for pair in started {
                    pair.close()
                }
                for socket in sockets {
                    try? socket.close()
                }
                throw error
            }
        }
    }

    private static func connectToHost(port: UInt32) throws -> Socket {
        let socket = try Socket(type: VsockType(port: port, cid: VsockType.hostCID), closeOnDeinit: false)
        try socket.connect()
        return socket
    }

    func closeStdin() throws {
        self.state.withLock {
            if let stdin = $0.stdin {
                stdin.close()
                $0.stdin = nil
            }
            // This is what gives the process its EOF. If the relay is still flushing, its
            // duplicate keeps the pipe open until it is done.
            try? $0.stdinWriter?.close()
            $0.stdinWriter = nil
        }
    }

    func closeAfterExec() throws {
        try self.state.withLock {
            if let stdin = $0.stdinPipe {
                try stdin.fileHandleForReading.close()
                $0.stdinPipe = nil
            }
            if let stdout = $0.stdoutPipe {
                try stdout.fileHandleForWriting.close()
                $0.stdoutPipe = nil
            }
            if let stderr = $0.stderrPipe {
                try stderr.fileHandleForWriting.close()
                $0.stderrPipe = nil
            }
        }
    }
}

#endif
