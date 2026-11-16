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

import Containerization
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GRPCCore

extension IntegrationSuite {
    private static let rootSleeperID = "sleeper"
    private static let rootCgroupRoot = "/sys/fs/cgroup/vminitd-root"
    private static let sigkillExitCode: Int32 = 128 + SIGKILL

    // Initfs has no dynamic loader; busybox runs through the container rootfs's.
    private static var guestMuslLoader: String {
        #if arch(x86_64)
        "lib/ld-musl-x86_64.so.1"
        #else
        "lib/ld-musl-aarch64.so.1"
        #endif
    }

    /// Runs busybox `sh` scripts as root-of-VM processes. `$B` runs a busybox applet.
    private struct RootShell {
        let vminitd: Vminitd
        let loader: String
        let busybox: String

        func start(
            _ id: String,
            _ script: String,
            capabilities: [CapabilityName] = [],
            resources: ContainerizationOCI.LinuxResources? = nil
        ) async throws {
            var process = ContainerizationOCI.Process(args: [loader, busybox, "sh", "-c", script], env: ["B=\(loader) \(busybox)"])
            if !capabilities.isEmpty {
                process.capabilities = LinuxCapabilities(capabilities: capabilities).toOCI()
            }

            try await vminitd.createProcess(
                id: id,
                containerID: nil,
                stdinPort: nil,
                stdoutPort: nil,
                stderrPort: nil,
                ociRuntimePath: nil,
                configuration: ContainerizationOCI.Spec(process: process, linux: resources.map { ContainerizationOCI.Linux(resources: $0) }),
                options: nil
            )
            _ = try await vminitd.startProcess(id: id, containerID: nil)
        }

        /// Returns the script's exit code.
        func run(
            _ id: String,
            _ script: String,
            capabilities: [CapabilityName] = [],
            resources: ContainerizationOCI.LinuxResources? = nil
        ) async throws -> Int32 {
            try await start(id, script, capabilities: capabilities, resources: resources)
            let status = try await vminitd.waitProcess(id: id, containerID: nil)
            try await vminitd.deleteProcess(id: id, containerID: nil)
            return status.exitCode
        }
    }

    /// Boots a pod with one sleeping container and runs `body` against its VM root.
    private func withRootShell(
        _ id: String,
        configure: (inout LinuxPod.Configuration) -> Void = { _ in },
        _ body: (RootShell) async throws -> Void
    ) async throws {
        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm, vm: .default) { config in
            config.bootLog = bs.bootLog
            configure(&config)
        }
        try await pod.addContainer(Self.rootSleeperID, rootfs: bs.rootfs) { config in
            config.process.arguments = ["sleep", "100"]
        }

        do {
            try await pod.create()
            try await pod.startContainer(Self.rootSleeperID)

            let vsock = try await pod.dialVsock(port: Vminitd.port)
            let vminitd = try await Vminitd(connection: vsock, group: Self.eventLoop)
            let rootfs = "/run/container/\(Self.rootSleeperID)/rootfs"
            try await body(RootShell(vminitd: vminitd, loader: "\(rootfs)/\(Self.guestMuslLoader)", busybox: "\(rootfs)/bin/busybox"))

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    /// Mount needs CAP_SYS_ADMIN and is visible to vminitd only from PID 1's mount namespace.
    func testPodRootProcessCapabilities() async throws {
        try await withRootShell("test-pod-root-process-capabilities") { shell in
            let mountpoint = "/run/root-process-probe"
            let mount = "$B mount -t tmpfs tmpfs \(mountpoint)"
            try await shell.vminitd.mkdir(path: mountpoint, all: true, perms: 0o755)
            let baselineDev = try await shell.vminitd.stat(root: "/", path: mountpoint).dev

            // vmexec drops the bounding set when the spec has no capabilities.
            let unprivileged = try await shell.run("root-unprivileged", mount)
            guard unprivileged != 0 else {
                throw IntegrationError.assert(msg: "mount without CAP_SYS_ADMIN succeeded")
            }
            guard try await shell.vminitd.stat(root: "/", path: mountpoint).dev == baselineDev else {
                throw IntegrationError.assert(msg: "mount without CAP_SYS_ADMIN is visible at \(mountpoint)")
            }

            let privileged = try await shell.run("root-privileged", mount, capabilities: [.sysAdmin])
            guard privileged == 0 else {
                throw IntegrationError.assert(msg: "mount with CAP_SYS_ADMIN exited \(privileged)")
            }
            guard try await shell.vminitd.stat(root: "/", path: mountpoint).dev != baselineDev else {
                throw IntegrationError.assert(msg: "mount is not visible to vminitd at \(mountpoint)")
            }
            try await shell.vminitd.umount(path: mountpoint, flags: 0)
        }
    }

    /// A root process shares PID 1's namespaces and can inspect the container's.
    func testPodRootProcessNamespaces() async throws {
        try await withRootShell("test-pod-root-process-namespaces") { shell in
            // Pod containers share the VM's net namespace.
            let containerNamespaces = "cgroup ipc mnt pid uts"
            let status = try await shell.run(
                "root-namespaces",
                """
                c=$($B pidof sleep) || exit 10
                for n in \(containerNamespaces) net; do
                    [ "$($B readlink /proc/self/ns/$n)" = "$($B readlink /proc/1/ns/$n)" ] || exit 11
                done
                for n in \(containerNamespaces); do
                    t=$($B readlink /proc/$c/ns/$n) || exit 12
                    [ "$t" != "$($B readlink /proc/self/ns/$n)" ] || exit 13
                done
                [ -f /proc/$c/root/etc/alpine-release ] || exit 14
                """,
                capabilities: [.sysPtrace]
            )
            guard status == 0 else {
                throw IntegrationError.assert(
                    msg: "exited \(status): 10 no container pid, 11 not in PID 1's ns, 12 container ns unreadable, 13 container shares ns, 14 container root unreadable")
            }
        }
    }

    func testPodRootProcessDNS() async throws {
        let nameserver = "1.1.1.1"
        try await withRootShell("test-pod-root-process-dns", configure: { $0.dns = DNS(nameservers: [nameserver]) }) { shell in
            let status = try await shell.run("root-dns", "$B grep -qx 'nameserver \(nameserver)' /etc/resolv.conf")
            guard status == 0 else {
                throw IntegrationError.assert(msg: "VM root /etc/resolv.conf lacks nameserver \(nameserver)")
            }
        }
    }

    /// A root process runs in its own cgroup with the spec's limits.
    func testPodRootProcessCgroup() async throws {
        let memoryLimit: Int64 = 64 * 1024 * 1024
        let memoryHigh: UInt64 = 128 * 1024 * 1024
        let cgroupRoot = Self.rootCgroupRoot

        try await withRootShell("test-pod-root-process-cgroup") { shell in
            let limitedID = "root-limited"
            let limited = try await shell.run(
                limitedID,
                """
                [ "$($B cat /proc/self/cgroup)" = "0::/vminitd-root/\(limitedID)" ] || exit 10
                [ "$($B cat \(cgroupRoot)/\(limitedID)/memory.max)" = "\(memoryLimit)" ] || exit 11
                [ "$($B cat \(cgroupRoot)/\(limitedID)/memory.high)" = "max" ] || exit 12
                """,
                resources: .init(memory: .init(limit: memoryLimit))
            )
            guard limited == 0 else {
                throw IntegrationError.assert(msg: "\(limitedID) exited \(limited): 10 wrong cgroup, 11 wrong memory.max, 12 memory.high not max")
            }

            let defaultID = "root-default"
            let defaulted = try await shell.run(defaultID, #"[ "$($B cat \#(cgroupRoot)/\#(defaultID)/memory.high)" = "max" ]"#)
            guard defaulted == 0 else {
                throw IntegrationError.assert(msg: "\(defaultID): memory.high is not max")
            }

            let highID = "root-memory-high"
            let high = try await shell.run(
                highID,
                #"[ "$($B cat \#(cgroupRoot)/\#(highID)/memory.high)" = "\#(memoryHigh)" ]"#,
                resources: .init(unified: ["memory.high": "\(memoryHigh)"])
            )
            guard high == 0 else {
                throw IntegrationError.assert(msg: "\(highID): memory.high is not the spec's \(memoryHigh)")
            }

            // Cgroups outlive delete; stat throws if one is gone.
            for processID in [limitedID, defaultID] {
                _ = try await shell.vminitd.stat(root: "/", path: "\(cgroupRoot)/\(processID)")
            }

            // Reusing an id would inherit the old cgroup's limits.
            do {
                try await shell.start(limitedID, "true")
                throw IntegrationError.assert(msg: "reusing root process id \(limitedID) should fail")
            } catch {
                guard let err = error as? RPCError, err.code == .alreadyExists, err.message.contains("already used") else {
                    throw error
                }
            }

            let sleeperID = "root-sleeper"
            try await shell.start(sleeperID, "exec $B sleep 100")
            try await shell.vminitd.signalProcess(id: sleeperID, containerID: nil, signal: SIGKILL)
            let killed = try await shell.vminitd.waitProcess(id: sleeperID, containerID: nil)
            guard killed.exitCode == Self.sigkillExitCode else {
                throw IntegrationError.assert(msg: "expected exit \(Self.sigkillExitCode) from SIGKILL, got \(killed.exitCode)")
            }
            try await shell.vminitd.deleteProcess(id: sleeperID, containerID: nil)
        }
    }

    func testPodRootProcessRejectsInvalid() async throws {
        // Never dialed.
        let stdinPort: UInt32 = 5000

        let plain = ContainerizationOCI.Process(args: ["/sbin/vmexec", "--version"])
        var withTerminal = plain
        withTerminal.terminal = true

        try await withRootShell("test-pod-root-process-rejects-invalid") { shell in
            let cases: [(id: String, stdinPort: UInt32?, process: ContainerizationOCI.Process)] = [
                ("root-stdin", stdinPort, plain),
                ("root-terminal", nil, withTerminal),
                ("", nil, plain),
                ("..", nil, plain),
                ("../escape", nil, plain),
            ]
            for testCase in cases {
                do {
                    try await shell.vminitd.createProcess(
                        id: testCase.id,
                        containerID: nil,
                        stdinPort: testCase.stdinPort,
                        stdoutPort: nil,
                        stderrPort: nil,
                        ociRuntimePath: nil,
                        configuration: ContainerizationOCI.Spec(process: testCase.process),
                        options: nil
                    )
                    throw IntegrationError.assert(msg: "root process '\(testCase.id)' was created; expected rejection")
                } catch {
                    guard let err = error as? RPCError, err.code == .invalidArgument else {
                        throw error
                    }
                }
            }
        }
    }

    private static let shareVolumeName = "share"

    /// A host directory holding `hello`, for a virtiofs pod volume.
    private static func makeShareDir(_ testID: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: testID)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello".write(to: dir.appending(path: "hello"), atomically: true, encoding: .utf8)
        return dir
    }

    private static func shareVolume(_ dir: URL, readOnly: Bool) -> LinuxPod.PodVolume {
        LinuxPod.PodVolume(name: shareVolumeName, source: .virtiofs(path: dir, readOnly: readOnly), format: "virtiofs")
    }

    /// Read-only holds at the share: a CAP_SYS_ADMIN remount cannot make it writable.
    func testPodVirtiofsVolumeReadOnly() async throws {
        let id = "test-pod-virtiofs-volume-ro"
        let dir = try Self.makeShareDir(id)
        let guest = "/run/volumes/\(Self.shareVolumeName)"

        try await withRootShell(id, configure: { $0.volumes = [Self.shareVolume(dir, readOnly: true)] }) { shell in
            let status = try await shell.run(
                "virtiofs-ro",
                """
                [ "$($B cat \(guest)/hello)" = "hello" ] || exit 10
                $B touch \(guest)/new 2>/dev/null && exit 11
                $B mount -o remount,rw \(guest) || exit 13
                $B touch \(guest)/new 2>/dev/null && exit 12
                exit 0
                """,
                capabilities: [.sysAdmin]
            )
            guard status == 0 else {
                throw IntegrationError.assert(msg: "exited \(status): 10 host file unreadable, 11 write succeeded, 12 write succeeded after remount, 13 remount failed")
            }
        }

        guard !FileManager.default.fileExists(atPath: dir.appending(path: "new").path) else {
            throw IntegrationError.assert(msg: "guest write reached the host through a read-only share")
        }
    }

    func testPodVirtiofsVolumeWritable() async throws {
        let id = "test-pod-virtiofs-volume-rw"
        let dir = try Self.makeShareDir(id)

        try await withRootShell(id, configure: { $0.volumes = [Self.shareVolume(dir, readOnly: false)] }) { shell in
            let status = try await shell.run("virtiofs-rw", "$B touch /run/volumes/\(Self.shareVolumeName)/new")
            guard status == 0 else {
                throw IntegrationError.assert(msg: "write to writable virtiofs volume exited \(status)")
            }
        }

        guard FileManager.default.fileExists(atPath: dir.appending(path: "new").path) else {
            throw IntegrationError.assert(msg: "guest write did not reach the host")
        }
    }

    /// startProcess throws if vmexec cannot exec the script.
    func testPodVirtiofsVolumeExec() async throws {
        let id = "test-pod-virtiofs-volume-exec"
        let dir = try Self.makeShareDir(id)
        // Kernel applies the share's noexec check to the script itself; /sbin/vmexec comes from the initfs.
        let script = dir.appending(path: "probe")
        try "#!/sbin/vmexec\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        try await withRootShell(id, configure: { $0.volumes = [Self.shareVolume(dir, readOnly: true)] }) { shell in
            let processID = "virtiofs-exec"
            let process = ContainerizationOCI.Process(args: ["/run/volumes/\(Self.shareVolumeName)/probe"])
            try await shell.vminitd.createProcess(
                id: processID,
                containerID: nil,
                stdinPort: nil,
                stdoutPort: nil,
                stderrPort: nil,
                ociRuntimePath: nil,
                configuration: ContainerizationOCI.Spec(process: process),
                options: nil
            )
            let pid = try await shell.vminitd.startProcess(id: processID, containerID: nil)
            guard pid > 0 else {
                throw IntegrationError.assert(msg: "startProcess returned pid \(pid)")
            }
            _ = try await shell.vminitd.waitProcess(id: processID, containerID: nil)
            try await shell.vminitd.deleteProcess(id: processID, containerID: nil)
        }
    }
}
