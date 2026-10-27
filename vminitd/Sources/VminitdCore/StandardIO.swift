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
