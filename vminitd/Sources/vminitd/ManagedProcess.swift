//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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
import NIOCore
import NIOPosix

class ManagedProcess: @unchecked Sendable {
    let id: String

    private let log: Logger
    private let io: IO
    private let process: Command

    private var waiters: [CheckedContinuation<Int32, Never>]
    private var exitStatus: Int32?
    private var closed: Bool
    private let lock = NSLock()
    private let syncfd: Pipe
    private let owningPid: Int32?
    private var _pid: Int32 = 0

    var pid: Int32 {
        self.lock.lock {
            _pid
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
            process.environment.append("TERM=xterm")
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

        self.io = io
        self.process = process
        self.waiters = []
        self.closed = false
    }
}

extension ManagedProcess {
    func start() throws -> Int32 {
        try self.lock.lock {
            log.debug("starting managed process")

            // Start the underlying process.
            try process.start()

            // Close our side of any pipes.
            try syncfd.fileHandleForWriting.close()
            try io.closeAfterExec()

            guard let piddata = try syncfd.fileHandleForReading.readToEnd() else {
                throw ContainerizationError(.internalError, message: "no pid data from sync pipe")
            }

            let i = piddata.withUnsafeBytes { ptr in
                ptr.load(as: Int32.self)
            }

            log.info("got back pid data \(i)")
            self._pid = i

            log.debug(
                "started managed process",
                metadata: [
                    "pid": "\(_pid)"
                ])
            return i
        }
    }

    func setExit(_ status: Int32) {
        self.lock.lock {
            self.log.debug(
                "managed process exit",
                metadata: [
                    "status": "\(status)"
                ])

            self.exitStatus = status

            for waiter in self.waiters {
                waiter.resume(returning: status)
            }

            self.log.debug("\(self.waiters.count) managed process waiters signaled")
            self.waiters.removeAll()
        }
    }

    /// Wait on the process to exit
    func wait() async -> Int32 {
        await withCheckedContinuation { cont in
            self.lock.lock {
                if let status = exitStatus {
                    cont.resume(returning: status)
                    return
                }
                self.waiters.append(cont)
            }
        }
    }

    func kill(_ signal: Int32) throws {
        try self.lock.lock {
            guard exitStatus == nil else {
                return
            }

            self.log.info("sending signal \(signal) to process \(_pid)")
            guard Foundation.kill(_pid, signal) == 0 else {
                throw POSIXError.fromErrno()
            }
        }
    }

    func resize(size: Terminal.Size) throws {
        try self.lock.lock {
            if self.closed {
                return
            }
            try self.io.resize(size: size)
        }
    }

    func close() throws {
        try self.lock.lock {
            if self.closed {
                return
            }
            try self.io.close()
            self.closed = true
        }
    }
}
