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

import ArgumentParser
import ContainerizationOCI
import Foundation
import LCShim
import Logging
import Musl

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
        LoggingSystem.bootstrap(App.standardError)
        let log = Logger(label: "vmexec")

        let src = URL(fileURLWithPath: processPath)
        let processBytes = try Data(contentsOf: src)
        let process = try JSONDecoder().decode(
            ContainerizationOCI.Process.self,
            from: processBytes
        )
        try execInNamespaces(process: process, log: log)
    }

    static func enterNS(path: String, nsType: Int32) throws {
        let fd = open(path, O_RDONLY)
        if fd <= 0 {
            throw App.Errno(stage: "open(ns)")
        }
        defer { close(fd) }

        guard setns(fd, nsType) == 0 else {
            throw App.Errno(stage: "setns(fd)")
        }
    }

    private func execInNamespaces(
        process: ContainerizationOCI.Process,
        log: Logger
    ) throws {
        // CLOEXEC the pipe fd that signals process readiness.
        let syncfd = FileHandle(fileDescriptor: 3)
        if fcntl(3, F_SETFD, FD_CLOEXEC) == -1 {
            throw App.Errno(stage: "cloexec(syncfd)")
        }

        try Self.enterNS(path: "/proc/\(self.parentPid)/ns/cgroup", nsType: CLONE_NEWCGROUP)
        try Self.enterNS(path: "/proc/\(self.parentPid)/ns/pid", nsType: CLONE_NEWPID)
        try Self.enterNS(path: "/proc/\(self.parentPid)/ns/uts", nsType: CLONE_NEWUTS)
        try Self.enterNS(path: "/proc/\(self.parentPid)/ns/mnt", nsType: CLONE_NEWNS)

        let childPipe = Pipe()
        try childPipe.setCloexec()
        let processID = fork()

        guard processID != -1 else {
            try? childPipe.fileHandleForReading.close()
            try? childPipe.fileHandleForWriting.close()
            try? syncfd.close()

            throw App.Errno(stage: "fork")
        }

        if processID == 0 {  // child
            try childPipe.fileHandleForReading.close()
            try syncfd.close()

            guard setsid() != -1 else {
                throw App.Errno(stage: "setsid()")
            }

            // Apply O_CLOEXEC to all file descriptors except stdio.
            // This ensures that all unwanted fds we may have accidentally
            // inherited are marked close-on-exec so they stay out of the
            // container.
            try App.applyCloseExecOnFDs()
            try App.setRLimits(rlimits: process.rlimits)

            // Change stdio to be owned by the requested user.
            try App.fixStdioPerms(user: process.user)

            // Set uid, gid, and supplementary groups
            try App.setPermissions(user: process.user)

            if process.terminal {
                guard ioctl(0, UInt(TIOCSCTTY), 0) != -1 else {
                    throw App.Errno(stage: "setctty()")
                }
            }

            try App.exec(process: process)
        } else {  // parent process
            try childPipe.fileHandleForWriting.close()

            // wait until the pipe is closed then carry on.
            _ = try childPipe.fileHandleForReading.readToEnd()
            try childPipe.fileHandleForReading.close()

            // send our child's pid to our parent before we exit.
            var childPid = processID
            let data = Data(bytes: &childPid, count: MemoryLayout.size(ofValue: childPid))

            try syncfd.write(contentsOf: data)
            try syncfd.close()
        }
    }
}
