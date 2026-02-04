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

                let pair = IOPair(
                    readFrom: stdinSocket,
                    writeTo: inPipe.fileHandleForWriting,
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

                let pair = IOPair(
                    readFrom: outPipe.fileHandleForReading,
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

                let pair = IOPair(
                    readFrom: errPipe.fileHandleForReading,
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
