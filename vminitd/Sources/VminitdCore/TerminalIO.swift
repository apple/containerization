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

import ContainerizationOS
import Foundation
import LCShim
import Logging
import Synchronization

final class TerminalIO: ManagedProcess.IO & Sendable {
    private struct State {
        var closed = false
        var stdinSocket: Socket?
        var stdoutSocket: Socket?

        var stdin: IOPair?
        var stdout: IOPair?
        var parent: Terminal?
        var parentOwner: OwnedDescriptor?
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
            if let parent = $0.parent, let owner = $0.parentOwner {
                let use = try owner.acquire()
                try withExtendedLifetime(use) { try parent.resize(size: size) }
            }
        }
    }

    func start(process: inout Command) throws {
        try self.state.withLock {
            guard !$0.closed else { throw SocketError.invalidOperationOnSocket("start closed terminal I/O") }
            process.stdin = nil
            process.stdout = nil
            process.stderr = nil

            if let stdinPort = self.hostStdio.stdin {
                let type = VsockType(
                    port: stdinPort,
                    cid: VsockType.hostCID
                )
                let stdinSocket = try Socket(type: type)
                try stdinSocket.connect()
                $0.stdinSocket = stdinSocket
            }

            if let stdoutPort = self.hostStdio.stdout {
                let type = VsockType(
                    port: stdoutPort,
                    cid: VsockType.hostCID
                )
                let stdoutSocket = try Socket(type: type)
                try stdoutSocket.connect()
                $0.stdoutSocket = stdoutSocket
            }
        }
    }

    func attach(pid: Int32, fd: Int32) throws {
        try self.state.withLock {
            guard !$0.closed, $0.parentOwner == nil else { throw SocketError.invalidOperationOnSocket("attach terminal I/O") }
        }
        do {
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

                let owner = OwnedDescriptor(adopting: Int32(hostFd))
                $0.parentOwner = owner
                // Terminal is a borrowed view; the session and stdout relay close the master.
                let term = try Terminal(descriptor: Int32(hostFd), setInitState: false)
                $0.parent = term

                if let stdinSocket = $0.stdinSocket {
                    let pair = IOPair(
                        readFrom: try stdinSocket.takeDescriptor(),
                        writeToBorrowed: owner,
                        reason: "TerminalIO stdin",
                        logger: log
                    )
                    try pair.relay(ignoreHup: true)
                    $0.stdin = pair
                    $0.stdinSocket = nil
                }

                if let stdoutSocket = $0.stdoutSocket {
                    let pair = IOPair(
                        readFromTerminal: owner,
                        writeTo: try stdoutSocket.takeDescriptor(),
                        reason: "TerminalIO stdout",
                        logger: log
                    )
                    try pair.relay(ignoreHup: true)
                    $0.stdout = pair
                    $0.stdoutSocket = nil
                }
            }
        } catch {
            try? self.close()
            throw error
        }
    }

    func close() throws {
        self.state.withLock {
            $0.closed = true
            if let stdout = $0.stdout {
                stdout.close()
                $0.stdout = nil
            }
            if let stdin = $0.stdin {
                stdin.close()
                $0.stdin = nil
            }

            // If IOPairs were never created (process exited before attach),
            // close the sockets directly so the host sees EOF.
            if let stdinSocket = $0.stdinSocket {
                try? stdinSocket.close()
                $0.stdinSocket = nil
            }
            if let stdoutSocket = $0.stdoutSocket {
                try? stdoutSocket.close()
                $0.stdoutSocket = nil
            }

            $0.parent = nil
            try? $0.parentOwner?.close()
            $0.parentOwner = nil
        }
    }

    deinit { try? close() }

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

#endif
