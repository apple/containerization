//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
import Logging
import Synchronization

final class TerminalIO: ManagedProcess.IO & Sendable {
    private struct State {
        var stdin: IOPair?
        var stdout: IOPair?
    }

    private let parent: Terminal
    private let child: Terminal
    private let log: Logger?
    private let hostStdio: HostStdio
    private let state: Mutex<State>

    init(
        stdio: HostStdio,
        log: Logger?
    ) throws {
        let pair = try Terminal.create()
        self.parent = pair.parent
        self.child = pair.child
        self.state = Mutex(State())
        self.hostStdio = stdio
        self.log = log
    }

    func resize(size: Terminal.Size) throws {
        try parent.resize(size: size)
    }

    func start(process: inout Command) throws {
        try self.state.withLock {
            let ptyHandle = self.child.handle
            let useHandles = self.hostStdio.stdin != nil || self.hostStdio.stdout != nil
            // We currently set stdin to the controlling terminal always, so
            // it must be a valid pty descriptor.
            process.stdin = useHandles ? ptyHandle : nil

            let stdoutHandle = useHandles ? ptyHandle : nil
            process.stdout = stdoutHandle
            process.stderr = stdoutHandle

            if let stdinPort = self.hostStdio.stdin {
                let type = VsockType(
                    port: stdinPort,
                    cid: VsockType.hostCID
                )
                let stdinSocket = try Socket(type: type, closeOnDeinit: false)
                try stdinSocket.connect()

                let pair = IOPair(
                    readFrom: stdinSocket,
                    writeTo: self.parent.handle,
                    logger: self.log
                )
                $0.stdin = pair

                try pair.relay()
            }

            if let stdoutPort = self.hostStdio.stdout {
                let type = VsockType(
                    port: stdoutPort,
                    cid: VsockType.hostCID
                )
                let stdoutSocket = try Socket(type: type, closeOnDeinit: false)
                try stdoutSocket.connect()

                let pair = IOPair(
                    readFrom: self.parent.handle,
                    writeTo: stdoutSocket,
                    logger: self.log
                )
                $0.stdout = pair

                try pair.relay()
            }
        }
    }

    func closeStdin() throws {
        self.state.withLock {
            $0.stdin?.close()
        }
    }

    func closeAfterExec() throws {
        try child.close()
    }
}
