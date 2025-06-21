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

import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GRPC
import Logging
import Synchronization

final class ManagedProcess: Sendable {
    let id: String

    private let log: Logger
    private let process: Command
    private let lock: Mutex<State>
    private let syncfd: Pipe
    private let owningPid: Int32?

    private struct State {
        init(io: IO) {
            self.io = io
        }

        let io: IO
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var exitStatus: Int32? = nil
        var closed: Bool = false
        var pid: Int32 = 0
    }

    var pid: Int32 {
        self.lock.withLock {
            $0.pid
        }
    }

    // swiftlint: disable type_name
    protocol IO {
        func start() throws
        func closeAfterExec() throws
        func resize(size: Terminal.Size) throws
        func close() throws
    }
    // swiftlint: enable type_name

    static func localizeLogger(log: inout Logger, id: String) {
        log[metadataKey: "id"] = "\(id)"
    }

    init(
        id: String,
        stdio: HostStdio,
        bundle: ContainerizationOCI.Bundle,
        owningPid: Int32? = nil,
        log: Logger
    ) throws {
        self.id = id
        var log = log
        Self.localizeLogger(log: &log, id: id)
        self.log = log
        self.owningPid = owningPid

        let syncfd = Pipe()
        try syncfd.setCloexec()
        self.syncfd = syncfd

        let args: [String]
        if let owningPid {
            args = [
                "exec",
                "--parent-pid",
                "\(owningPid)",
                "--process-path",
                bundle.getExecSpecPath(id: id).path,
            ]
        } else {
            args = ["run", "--bundle-path", bundle.path.path]
        }

        var process = Command(
            "/sbin/vmexec",
            arguments: args,
            extraFiles: [syncfd.fileHandleForWriting]
        )

        var io: IO
        if stdio.terminal {
            log.info("setting up terminal IO")
            let attrs = Command.Attrs(setsid: false, setctty: false)
            process.attrs = attrs
            io = try TerminalIO(
                process: &process,
                stdio: stdio,
                log: log
            )
        } else {
            process.attrs = .init(setsid: false)
            io = StandardIO(
                process: &process,
                stdio: stdio,
                log: log
            )
        }

        log.info("starting io")

        // Setup IO early. We expect the host to be listening already.
        try io.start()

        self.process = process
        self.lock = Mutex(State(io: io))
    }
}

extension ManagedProcess {
    func start() throws -> Int32 {
        try self.lock.withLock {
            log.debug(
                "starting managed process",
                metadata: [
                    "id": "\(id)"
                ])

            // Start the underlying process.
            try process.start()

            // Close our side of any pipes.
            try syncfd.fileHandleForWriting.close()
            try $0.io.closeAfterExec()

            guard let piddata = try syncfd.fileHandleForReading.readToEnd() else {
                throw ContainerizationError(.internalError, message: "no pid data from sync pipe")
            }

            let i = piddata.withUnsafeBytes { ptr in
                ptr.load(as: Int32.self)
            }

            log.info("got back pid data \(i)")
            $0.pid = i

            log.debug(
                "started managed process",
                metadata: [
                    "pid": "\(i)",
                    "id": "\(id)",
                ])

            return i
        }
    }

    func setExit(_ status: Int32) {
        self.lock.withLock {
            self.log.debug(
                "managed process exit",
                metadata: [
                    "status": "\(status)"
                ])

            $0.exitStatus = status

            for waiter in $0.waiters {
                waiter.resume(returning: status)
            }

            self.log.debug("\($0.waiters.count) managed process waiters signaled")
            $0.waiters.removeAll()
        }
    }

    /// Wait on the process to exit
    func wait() async -> Int32 {
        await withCheckedContinuation { cont in
            self.lock.withLock {
                if let status = $0.exitStatus {
                    cont.resume(returning: status)
                    return
                }
                $0.waiters.append(cont)
            }
        }
    }

    func kill(_ signal: Int32) throws {
        try self.lock.withLock {
            guard $0.exitStatus == nil else {
                return
            }

            self.log.info("sending signal \(signal) to process \($0.pid)")
            guard Foundation.kill($0.pid, signal) == 0 else {
                throw POSIXError.fromErrno()
            }
        }
    }

    func resize(size: Terminal.Size) throws {
        try self.lock.withLock {
            if $0.closed {
                return
            }
            try $0.io.resize(size: size)
        }
    }

    func close() throws {
        try self.lock.withLock {
            if $0.closed {
                return
            }
            try $0.io.close()
            $0.closed = true
        }
    }
}
