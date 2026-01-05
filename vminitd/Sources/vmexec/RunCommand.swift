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
import Cgroup
import ContainerizationOCI
import ContainerizationOS
import Foundation
import LCShim
import Logging
import Musl

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a container"
    )

    @Option(name: .long, help: "path to an OCI bundle")
    var bundlePath: String

    mutating func run() throws {
        do {
            let spec: ContainerizationOCI.Spec
            do {
                let bundle = try ContainerizationOCI.Bundle.load(path: URL(filePath: bundlePath))
                spec = try bundle.loadConfig()
            } catch {
                throw App.Failure(message: "failed to load OCI bundle at \(bundlePath): \(error)")
            }
            try execInNamespace(spec: spec)
        } catch {
            App.writeError(error)
            throw error
        }
    }

    private func childRootSetup(rootfs: ContainerizationOCI.Root, mounts: [ContainerizationOCI.Mount]) throws {
        // setup rootfs
        try prepareRoot(rootfs: rootfs.path)
        try mountRootfs(rootfs: rootfs.path, mounts: mounts)
        try setDevSymlinks(rootfs: rootfs.path)

        try pivotRoot(rootfs: rootfs.path)

        // Remount ro if requested.
        if rootfs.readonly {
            try self.remountRootfsReadOnly()
        }

        try reOpenDevNull()
    }

    private func remountRootfsReadOnly() throws {
        var flags = UInt(MS_BIND | MS_REMOUNT | MS_RDONLY)

        let ret = mount("", "/", "", flags, "")
        if ret == 0 {
            return
        }

        var s = statfs()
        guard statfs("/", &s) == 0 else {
            throw App.Errno(stage: "statfs(/)")
        }
        flags |= s.f_flags

        guard mount("", "/", "", flags, "") == 0 else {
            throw App.Errno(stage: "mount rootfs ro")
        }
    }

    private func childSetup(
        spec: ContainerizationOCI.Spec,
        ackPipe: FileHandle,
        syncPipe: FileHandle,
    ) throws {
        guard let process = spec.process else {
            throw App.Failure(message: "no process configuration found in runtime spec")
        }
        guard let root = spec.root else {
            throw App.Failure(message: "no root found in runtime spec")
        }

        // Wait for the grandparent to tell us that they acked our pid.
        guard let data = try ackPipe.read(upToCount: App.ackPid.count) else {
            throw App.Failure(message: "read ack pipe")
        }
        guard let pidAckStr = String(data: data, encoding: .utf8) else {
            throw App.Failure(message: "convert ack pipe data to string")
        }

        guard pidAckStr == App.ackPid else {
            throw App.Failure(message: "received invalid acknowledgement string: \(pidAckStr)")
        }

        guard unshare(CLONE_NEWCGROUP) == 0 else {
            throw App.Errno(stage: "unshare(cgroup)")
        }

        guard setsid() != -1 else {
            throw App.Errno(stage: "setsid()")
        }

        try childRootSetup(rootfs: root, mounts: spec.mounts)

        if process.terminal {
            let pty = try Console()
            try pty.configureStdIO()
            var masterFD = pty.master

            let data = Data(bytes: &masterFD, count: MemoryLayout.size(ofValue: masterFD))
            try syncPipe.write(contentsOf: data)

            // Wait for the grandparent to tell us that they acked our console.
            guard let data = try ackPipe.read(upToCount: App.ackConsole.count) else {
                throw App.Failure(message: "read ack pipe")
            }

            guard let consoleAckStr = String(data: data, encoding: .utf8) else {
                throw App.Failure(message: "convert ack pipe data to string")
            }

            guard consoleAckStr == App.ackConsole else {
                throw App.Failure(message: "received invalid acknowledgement string: \(consoleAckStr)")
            }

            guard ioctl(0, UInt(TIOCSCTTY), 0) != -1 else {
                throw App.Errno(stage: "setctty(0)")
            }

            try mountConsole(path: pty.slavePath)
            try pty.close()
        }

        if !spec.hostname.isEmpty {
            let errCode = spec.hostname.withCString { ptr in
                Musl.sethostname(ptr, spec.hostname.count)
            }
            guard errCode == 0 else {
                throw App.Errno(stage: "sethostname()")
            }
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

        // Set uid, gid, and supplementary groups.
        try App.setPermissions(user: process.user)

        // Finish capabilities (after user change)
        try App.finishCapabilities(preparedCaps)

        // Finally execve the container process.
        try App.exec(process: process, currentEnv: process.env)
    }

    private func setupNamespaces(namespaces: [ContainerizationOCI.LinuxNamespace]?) throws -> Int32 {
        var unshareFlags: Int32 = 0

        // Map namespace types to their corresponding CLONE flags
        let nsTypeToFlag: [ContainerizationOCI.LinuxNamespaceType: Int32] = [
            .pid: CLONE_NEWPID,
            .mount: CLONE_NEWNS,
            .uts: CLONE_NEWUTS,
            .ipc: CLONE_NEWIPC,
            .user: CLONE_NEWUSER,
            .cgroup: CLONE_NEWCGROUP,
        ]

        guard let namespaces = namespaces else {
            return CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUTS
        }

        for ns in namespaces {
            guard let flag = nsTypeToFlag[ns.type] else {
                continue
            }

            if ns.path.isEmpty {
                unshareFlags |= flag
            } else {
                let fd = open(ns.path, O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else {
                    throw App.Errno(stage: "open(\(ns.path))")
                }
                defer { close(fd) }

                guard setns(fd, flag) == 0 else {
                    throw App.Errno(stage: "setns(\(ns.path))")
                }
            }
        }

        return unshareFlags
    }

    private func execInNamespace(spec: ContainerizationOCI.Spec) throws {
        let syncPipe = FileHandle(fileDescriptor: 3)
        let ackPipe = FileHandle(fileDescriptor: 4)

        let unshareFlags = try setupNamespaces(namespaces: spec.linux?.namespaces)

        guard unshare(unshareFlags) == 0 else {
            throw App.Errno(stage: "unshare(\(unshareFlags))")
        }

        let processID = fork()
        guard processID != -1 else {
            try? syncPipe.close()
            try? ackPipe.close()
            throw App.Errno(stage: "fork")
        }

        if processID == 0 {  // child
            try childSetup(spec: spec, ackPipe: ackPipe, syncPipe: syncPipe)
        } else {  // parent process
            // Setup cgroup before child enters cgroup namespace
            if let linux = spec.linux {
                let cgroupPath = linux.cgroupsPath
                if !cgroupPath.isEmpty {
                    let cgroupManager = try Cgroup2Manager.load(group: URL(filePath: cgroupPath))

                    if let resources = linux.resources {
                        try cgroupManager.applyResources(resources: resources)
                    }

                    try cgroupManager.addProcess(pid: processID)
                }
            }

            // Send our child's pid before we exit.
            var childPid = processID
            let data = Data(bytes: &childPid, count: MemoryLayout.size(ofValue: childPid))
            try syncPipe.write(contentsOf: data)
        }
    }

    private func mountRootfs(rootfs: String, mounts: [ContainerizationOCI.Mount]) throws {
        let containerMount = ContainerMount(rootfs: rootfs, mounts: mounts)
        try containerMount.mountToRootfs()
        try containerMount.configureConsole()
    }

    private func prepareRoot(rootfs: String) throws {
        guard mount("", "/", "", UInt(MS_SLAVE | MS_REC), nil) == 0 else {
            throw App.Errno(stage: "mount(slave|rec)")
        }

        guard mount(rootfs, rootfs, "bind", UInt(MS_BIND | MS_REC), nil) == 0 else {
            throw App.Errno(stage: "mount(bind|rec)")
        }
    }

    private func setDevSymlinks(rootfs: String) throws {
        let links: [(src: String, dst: String)] = [
            ("/proc/self/fd", "/dev/fd"),
            ("/proc/self/fd/0", "/dev/stdin"),
            ("/proc/self/fd/1", "/dev/stdout"),
            ("/proc/self/fd/2", "/dev/stderr"),
            ("/dev/rtc0", "/dev/rtc"),
        ]

        let rootfsURL = URL(fileURLWithPath: rootfs)
        for (src, dst) in links {
            let dest = rootfsURL.appendingPathComponent(dst)
            guard symlink(src, dest.path) == 0 else {
                if errno == EEXIST {
                    continue
                }
                throw App.Errno(stage: "symlink(\(src) -> \(dest.path))")
            }
        }
    }

    private func reOpenDevNull() throws {
        let file = open("/dev/null", O_RDWR)
        guard file != -1 else {
            throw App.Errno(stage: "open(/dev/null)")
        }
        defer { close(file) }

        var devNullStat = stat()
        try withUnsafeMutablePointer(to: &devNullStat) { pointer in
            guard fstat(file, pointer) == 0 else {
                throw App.Errno(stage: "fstat(/dev/null)")
            }
        }

        for fd: Int32 in 0...2 {
            var fdStat = stat()
            try withUnsafeMutablePointer(to: &fdStat) { pointer in
                guard fstat(fd, pointer) == 0 else {
                    throw App.Errno(stage: "fstat(fd)")
                }
            }

            if fdStat.st_rdev == devNullStat.st_rdev {
                guard dup3(file, fd, 0) != -1 else {
                    throw App.Errno(stage: "dup3(null)")
                }
            }
        }
    }

    /// Pivots the rootfs of the calling process in the namespace to the provided
    /// rootfs in the argument.
    ///
    /// The pivot_root(".", ".") and unmount old root approach is exactly the same
    /// as runc's pivot root implementation in:
    /// https://github.com/opencontainers/runc/blob/main/libcontainer/rootfs_linux.go
    private func pivotRoot(rootfs: String) throws {
        let oldRoot = open("/", O_RDONLY | O_DIRECTORY)
        if oldRoot <= 0 {
            throw App.Errno(stage: "open(oldroot)")
        }
        defer { close(oldRoot) }

        let newRoot = open(rootfs, O_RDONLY | O_DIRECTORY)
        if newRoot <= 0 {
            throw App.Errno(stage: "open(newroot)")
        }
        defer { close(newRoot) }

        // change cwd to the new root
        guard fchdir(newRoot) == 0 else {
            throw App.Errno(stage: "fchdir(newroot)")
        }
        guard CZ_pivot_root(toCString("."), toCString(".")) == 0 else {
            throw App.Errno(stage: "pivot_root()")
        }
        // change cwd to the old root
        guard fchdir(oldRoot) == 0 else {
            throw App.Errno(stage: "fchdir(oldroot)")
        }
        // mount old root rslave so that unmount doesn't propagate back to outside
        // the namespace
        guard mount("", ".", "", UInt(MS_SLAVE | MS_REC), nil) == 0 else {
            throw App.Errno(stage: "mount(., slave|rec)")
        }
        // unmount old root
        guard umount2(".", Int32(MNT_DETACH)) == 0 else {
            throw App.Errno(stage: "umount(.)")
        }
        // switch cwd to the new root
        guard chdir("/") == 0 else {
            throw App.Errno(stage: "chdir(/)")
        }
    }

    private func toCString(_ str: String) -> UnsafeMutablePointer<CChar>? {
        let cString = str.utf8CString
        let cStringCopy = UnsafeMutableBufferPointer<CChar>.allocate(capacity: cString.count)
        _ = cStringCopy.initialize(from: cString)
        return UnsafeMutablePointer(cStringCopy.baseAddress)
    }

    private func mountConsole(path: String) throws {
        let console = "/dev/console"
        if access(console, F_OK) != 0 {
            let fd = open(console, O_RDWR | O_CREAT, mode_t(UInt16(0o600)))
            guard fd != -1 else {
                throw App.Errno(stage: "open(/dev/console)")
            }
            close(fd)
        }

        guard mount(path, console, "bind", UInt(MS_BIND), nil) == 0 else {
            throw App.Errno(stage: "mount(console)")
        }
    }
}
