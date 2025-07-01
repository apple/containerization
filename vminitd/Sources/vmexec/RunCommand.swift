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

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a container"
    )

    @Option(name: .long, help: "path to an OCI bundle")
    var bundlePath: String

    mutating func run() throws {
        LoggingSystem.bootstrap(App.standardError)
        let log = Logger(label: "vmexec")

        let bundle = try ContainerizationOCI.Bundle.load(path: URL(filePath: bundlePath))
        let ociSpec = try bundle.loadConfig()
        try execInNamespace(spec: ociSpec, log: log)
    }

    private func childRootSetup(rootfs: ContainerizationOCI.Root, mounts: [ContainerizationOCI.Mount], log: Logger) throws {
        // setup rootfs
        try prepareRoot(rootfs: rootfs.path)
        try mountRootfs(rootfs: rootfs.path, mounts: mounts)
        try setDevSymlinks(rootfs: rootfs.path)

        try pivotRoot(rootfs: rootfs.path)
        try reOpenDevNull()
    }

    private func execInNamespace(spec: ContainerizationOCI.Spec, log: Logger) throws {
        guard let process = spec.process else {
            fatalError("no process configuration found in runtime spec")
        }
        guard let root = spec.root else {
            fatalError("no root found in runtime spec")
        }

        let syncfd = FileHandle(fileDescriptor: 3)
        if fcntl(3, F_SETFD, FD_CLOEXEC) == -1 {
            throw App.Errno(stage: "cloexec(syncfd)")
        }

        guard unshare(CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUTS) == 0 else {
            throw App.Errno(stage: "unshare(pid|mnt|uts)")
        }

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

            guard unshare(CLONE_NEWCGROUP) == 0 else {
                throw App.Errno(stage: "unshare(cgroup)")
            }

            guard setsid() != -1 else {
                throw App.Errno(stage: "setsid()")
            }

            try childRootSetup(rootfs: root, mounts: spec.mounts, log: log)

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

            // Change stdio to be owned by the requested user.
            try App.fixStdioPerms(user: process.user)

            // Set uid, gid, and supplementary groups.
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
        ]

        let rootfsURL = URL(fileURLWithPath: rootfs)
        for (src, dst) in links {
            let dest = rootfsURL.appendingPathComponent(dst)
            guard symlink(src, dest.path) == 0 else {
                if errno == EEXIST {
                    continue
                }
                throw App.Errno(stage: "symlink()")
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
}
