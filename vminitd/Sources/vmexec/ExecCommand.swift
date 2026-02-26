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

import ArgumentParser
import ContainerizationOCI
import ContainerizationOS
import FoundationEssentials
import LCShim
import Logging
import Musl
import SystemPackage

struct ExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Exec in a container"
    )

    @Option(name: .long, help: "path to an OCI runtime spec process configuration")
    var processPath: String

    @Option(name: .long, help: "pid of the init process for the container")
    var parentPid: Int

    func run() throws {
        do {
            let src = URL(fileURLWithPath: processPath)
            let processBytes = try Data(contentsOf: src)
            let process = try JSONDecoder().decode(
                ContainerizationOCI.Process.self,
                from: processBytes
            )
            try execInNamespaces(process: process)
        } catch {
            App.writeError(error)
            throw error
        }
    }

    static func enterNS(pidFd: Int32, nsType: Int32) throws {
        guard setns(pidFd, nsType) == 0 else {
            throw App.Errno(stage: "setns(fd)")
        }
    }

    private func execInNamespaces(process: ContainerizationOCI.Process) throws {
        let syncPipe = FileDescriptor(rawValue: 3)
        let ackPipe = FileDescriptor(rawValue: 4)

        let pidFd = CZ_pidfd_open(Int32(parentPid), 0)
        guard pidFd > 0 else {
            throw App.Errno(stage: "pidfd_open(\(parentPid))")
        }
        try Self.enterNS(
            pidFd: pidFd,
            nsType: CLONE_NEWCGROUP | CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWNS
        )

        let processID = fork()

        guard processID != -1 else {
            try? syncPipe.close()
            try? ackPipe.close()

            throw App.Errno(stage: "fork")
        }

        if processID == 0 {  // child
            // Wait for the grandparent to tell us that they acked our pid.
            var pidAckBuffer = [UInt8](repeating: 0, count: App.ackPid.count)
            let pidAckBytesRead = try pidAckBuffer.withUnsafeMutableBytes { buffer in
                try ackPipe.read(into: buffer)
            }
            guard pidAckBytesRead > 0 else {
                throw App.Failure(message: "read ack pipe")
            }
            let pidAckStr = String(decoding: pidAckBuffer[..<pidAckBytesRead], as: UTF8.self)

            guard pidAckStr == App.ackPid else {
                throw App.Failure(message: "received invalid acknowledgement string: \(pidAckStr)")
            }

            guard setsid() != -1 else {
                throw App.Errno(stage: "setsid()")
            }

            if process.terminal {
                let pty = try Console()
                try pty.configureStdIO()
                var masterFD = pty.master

                try withUnsafeBytes(of: &masterFD) { bytes in
                    _ = try syncPipe.write(bytes)
                }

                // Wait for the grandparent to tell us that they acked our console.
                var consoleAckBuffer = [UInt8](repeating: 0, count: App.ackConsole.count)
                let consoleAckBytesRead = try consoleAckBuffer.withUnsafeMutableBytes { buffer in
                    try ackPipe.read(into: buffer)
                }
                guard consoleAckBytesRead > 0 else {
                    throw App.Failure(message: "read ack pipe")
                }
                let consoleAckStr = String(decoding: consoleAckBuffer[..<consoleAckBytesRead], as: UTF8.self)

                guard consoleAckStr == App.ackConsole else {
                    throw App.Failure(message: "received invalid acknowledgement string: \(consoleAckStr)")
                }

                guard ioctl(0, UInt(TIOCSCTTY), 0) != -1 else {
                    throw App.Errno(stage: "setctty(0)")
                }
                try pty.close()
            }

            // Apply O_CLOEXEC to all file descriptors except stdio.
            // This ensures that all unwanted fds we may have accidentally
            // inherited are marked close-on-exec so they stay out of the
            // container.
            try App.applyCloseExecOnFDs()
            try App.setRLimits(rlimits: process.rlimits)

            // Prepare capabilities (before user change)
            let preparedCaps = try App.prepareCapabilities(capabilities: process.capabilities ?? ContainerizationOCI.LinuxCapabilities())

            // Change stdio to be owned by the requested user.
            try App.fixStdioPerms(user: process.user)

            // Set uid, gid, and supplementary groups
            try App.setPermissions(user: process.user)

            // Finish capabilities (after user change)
            try App.finishCapabilities(preparedCaps)

            try App.exec(process: process, currentEnv: process.env)
        } else {  // parent process
            // Send our child's pid to our parent before we exit.
            var childPid = processID
            try withUnsafeBytes(of: &childPid) { bytes in
                _ = try syncPipe.write(bytes)
            }
        }
    }
}
