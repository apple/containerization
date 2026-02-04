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

import ContainerizationOS
import Foundation
import LCShim
import Logging
import Synchronization

final class TerminalIO: ManagedProcess.IO & Sendable {
    private struct State {
        var stdinSocket: Socket?
        var stdoutSocket: Socket?

        var stdin: IOPair?
        var stdout: IOPair?
        var parent: Terminal?
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
            if let parent = $0.parent {
                try parent.resize(size: size)
            }
        }
    }

    func start(process: inout Command) throws {
        try self.state.withLock {
            process.stdin = nil
            process.stdout = nil
            process.stderr = nil

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

    func attach(pid: Int32, fd: Int32) throws {
        try self.state.withLock {
            let containerFd = CZ_pidfd_open(pid, 0)
            guard containerFd != -1 else {
                throw POSIXError.fromErrno()
            }
            defer { Foundation.close(Int32(containerFd)) }

            let hostFd = CZ_pidfd_getfd(containerFd, fd, 0)
            guard hostFd != -1 else {
                throw POSIXError.fromErrno()
            }

            let term = try Terminal(descriptor: Int32(hostFd), setInitState: false)
            $0.parent = term

            if let stdinSocket = $0.stdinSocket {
                let pair = IOPair(
                    readFrom: stdinSocket,
                    writeTo: term,
                    reason: "TerminalIO stdin",
                    logger: log
                )
                try pair.relay(ignoreHup: true)
                $0.stdin = pair
            }

            if let stdoutSocket = $0.stdoutSocket {
                let pair = IOPair(
                    readFrom: term,
                    writeTo: stdoutSocket,
                    reason: "TerminalIO stdout",
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
            $0.parent = nil
        }
    }

    // NOP
    func closeAfterExec() throws {}

    func closeStdin() throws {
        self.state.withLock {
            if let stdin = $0.stdin {
                stdin.close()
                $0.stdin = nil
            }
        }
    }
}
