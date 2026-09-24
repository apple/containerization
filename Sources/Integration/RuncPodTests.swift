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
import Foundation

// Integration tests for the runc-backed pod path, selected with
// `LinuxPod.Configuration.ociRuntimePath`. Twins of the vmexec pod tests in
// PodTests.swift, plus the seccomp coverage that only an OCI runtime can honour.
extension IntegrationSuite {
    func testRuncPodMultipleContainers() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-pod-multiple-containers"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm, vm: .default) { config in
            config.ociRuntimePath = runtime
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/true"]
        }
        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/echo", "hello"]
        }

        do {
            try await withDeadline(seconds: 60, "runc pod create") { try await pod.create() }

            try await withDeadline(seconds: 60, "runc pod start container1") { try await pod.startContainer("container1") }
            let status1 = try await withDeadline(seconds: 60, "runc pod container1 to exit") { try await pod.waitContainer("container1") }

            try await withDeadline(seconds: 60, "runc pod start container2") { try await pod.startContainer("container2") }
            let status2 = try await withDeadline(seconds: 60, "runc pod container2 to exit") { try await pod.waitContainer("container2") }

            try await withDeadline(seconds: 60, "runc pod stop") { try await pod.stop() }

            guard status1.exitCode == 0 else {
                throw IntegrationError.assert(msg: "container1 status \(status1) != 0")
            }
            guard status2.exitCode == 0 else {
                throw IntegrationError.assert(msg: "container2 status \(status2) != 0")
            }
        } catch {
            try? await withDeadline(seconds: 60, "runc pod stop after failure") { try await pod.stop() }
            throw error
        }
    }

    func testRuncPodExecInContainer() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-pod-exec-in-container"

        let bs = try await bootstrap(id)
        let bootLogPath = self.resetBootLog(id: id)

        let pod = try LinuxPod(id, vmm: bs.vmm, vm: .default) { config in
            config.ociRuntimePath = runtime
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/sleep", "100"]
        }

        do {
            try await withDeadline(seconds: 60, "runc pod exec create") { try await pod.create() }
            try await withDeadline(seconds: 60, "runc pod exec start container") { try await pod.startContainer("container1") }

            let buffer = BufferWriter()
            let exec = try await pod.execInContainer("container1", processID: "runc-pod-exec-probe") { config in
                config.arguments = ["/bin/echo", "exec test"]
                config.stdout = buffer
            }

            try await withDeadline(seconds: 60, "runc pod exec start") { try await exec.start() }
            let status = try await withDeadline(seconds: 60, "runc pod exec to exit") { try await exec.wait() }
            try await withDeadline(seconds: 60, "runc pod exec delete") { try await exec.delete() }

            try await withDeadline(seconds: 60, "runc pod exec kill container") { try await pod.killContainer("container1", signal: .kill) }
            _ = try await withDeadline(seconds: 60, "runc pod exec container to exit") { try await pod.waitContainer("container1") }
            try await withDeadline(seconds: 60, "runc pod exec stop") { try await pod.stop() }

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec status \(status) != 0")
            }
            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard output == "exec test\n" else {
                throw IntegrationError.assert(msg: "exec should have returned 'exec test' != '\(output)'")
            }

            // `/bin/echo` behaves the same under either runtime, so nothing
            // above tells them apart. The guest picks an exec's runtime from the
            // container it belongs to, not from the request, so this asserts the
            // pod's runc-backed container execs through RuncExecProcess with its
            // I/O attached and its own exit status -- the seccomp tests cover
            // only the init path, an exec's spec carrying no profile.
            try self.assertRuncExec(execID: "runc-pod-exec-probe", in: try self.bootLogLines(at: bootLogPath))
        } catch {
            try? await withDeadline(seconds: 60, "runc pod exec stop after failure") { try await pod.stop() }
            throw error
        }
    }

    // The pod twin of testRuncProcessSeccompDefault. A pod-level profile has to
    // reach every container's init spec; without it the probe reports mode 0 and
    // the container runs unfiltered.
    func testRuncPodSeccompDefault() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-pod-seccomp-default"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm, vm: .default) { config in
            config.ociRuntimePath = runtime
            config.seccompProfile = .default
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/sh", "-c", Self.seccompStatusProbe]
            config.process.stdout = buffer
        }

        do {
            try await withDeadline(seconds: 60, "runc pod seccomp create") { try await pod.create() }
            try await withDeadline(seconds: 60, "runc pod seccomp start container") { try await pod.startContainer("container1") }
            let status = try await withDeadline(seconds: 60, "runc pod seccomp probe to exit") { try await pod.waitContainer("container1") }
            try await withDeadline(seconds: 60, "runc pod seccomp stop") { try await pod.stop() }

            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "seccomp probe failed (exit \(status.exitCode)): \(output)")
            }
            guard let parsed = Self.parseSeccompStatus(output) else {
                throw IntegrationError.assert(msg: "could not read Seccomp/Seccomp_filters from /proc/self/status: \(output)")
            }
            // 2 == SECCOMP_MODE_FILTER.
            guard parsed.mode == "2" else {
                throw IntegrationError.assert(msg: "expected 'Seccomp: 2' with the default profile, got 'Seccomp: \(parsed.mode)' in: \(output)")
            }
            guard parsed.filters > 0 else {
                throw IntegrationError.assert(msg: "expected a non-zero Seccomp_filters with the default profile, got \(parsed.filters) in: \(output)")
            }
            guard let usernsRC = parsed.usernsRC else {
                throw IntegrationError.assert(
                    msg: "the guest image has no 'unshare', so the behavioural half of this test exercised nothing; "
                        + "restore the applet or replace the probe: \(output)"
                )
            }
            guard usernsRC == 1, parsed.usernsError.lowercased().contains("not permitted") else {
                throw IntegrationError.assert(
                    msg: "expected 'unshare -U' to be denied with EPERM under the default profile, "
                        + "got rc \(usernsRC) and '\(parsed.usernsError)' in: \(output)"
                )
            }
        } catch {
            try? await withDeadline(seconds: 60, "runc pod seccomp stop after failure") { try await pod.stop() }
            throw error
        }
    }

    // A container's own profile beats the pod's, in both directions: one
    // container inherits the pod's default filter, its neighbour opts out. Both
    // run the same probe in the same VM, so a filter leaking across containers
    // shows up as a failure rather than as a pass.
    func testRuncPodSeccompContainerOverride() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-pod-seccomp-container-override"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm, vm: .default) { config in
            config.ociRuntimePath = runtime
            config.seccompProfile = .default
            config.bootLog = bs.bootLog
        }

        let inheritedBuffer = BufferWriter()
        try await pod.addContainer("inherited", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "inherited")) { config in
            config.process.arguments = ["/bin/sh", "-c", Self.seccompStatusProbe]
            config.process.stdout = inheritedBuffer
        }

        let overriddenBuffer = BufferWriter()
        try await pod.addContainer("overridden", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "overridden")) { config in
            config.seccompProfile = .unconfined
            config.process.arguments = ["/bin/sh", "-c", Self.seccompStatusProbe]
            config.process.stdout = overriddenBuffer
        }

        do {
            try await withDeadline(seconds: 60, "runc pod override create") { try await pod.create() }

            try await withDeadline(seconds: 60, "runc pod override start inherited") { try await pod.startContainer("inherited") }
            let inheritedStatus = try await withDeadline(seconds: 60, "runc pod override inherited to exit") {
                try await pod.waitContainer("inherited")
            }

            try await withDeadline(seconds: 60, "runc pod override start overridden") { try await pod.startContainer("overridden") }
            let overriddenStatus = try await withDeadline(seconds: 60, "runc pod override overridden to exit") {
                try await pod.waitContainer("overridden")
            }

            try await withDeadline(seconds: 60, "runc pod override stop") { try await pod.stop() }

            let inherited = try Self.requireSeccompProbe(inheritedBuffer, status: inheritedStatus, container: "inherited")
            let overridden = try Self.requireSeccompProbe(overriddenBuffer, status: overriddenStatus, container: "overridden")

            // 2 == SECCOMP_MODE_FILTER.
            guard inherited.mode == "2", inherited.filters > 0 else {
                throw IntegrationError.assert(
                    msg: "the container that set no profile should have inherited the pod's, got 'Seccomp: \(inherited.mode)' / "
                        + "'Seccomp_filters: \(inherited.filters)'"
                )
            }
            guard inherited.usernsRC == 1, inherited.usernsError.lowercased().contains("not permitted") else {
                let rc = inherited.usernsRC.map(String.init) ?? "no 'unshare' in the image"
                throw IntegrationError.assert(
                    msg: "expected 'unshare -U' to be denied in the inheriting container, got rc \(rc) and '\(inherited.usernsError)'"
                )
            }

            guard overridden.mode == "0", overridden.filters == 0 else {
                throw IntegrationError.assert(
                    msg: "the container that overrode to unconfined should run unfiltered, got 'Seccomp: \(overridden.mode)' / "
                        + "'Seccomp_filters: \(overridden.filters)'"
                )
            }
            guard overridden.usernsRC == 0 else {
                let rc = overridden.usernsRC.map(String.init) ?? "no 'unshare' in the image"
                throw IntegrationError.assert(
                    msg: "expected 'unshare -U' to succeed in the unconfined container (rc \(rc), '\(overridden.usernsError)'); "
                        + "the probe cannot discriminate if it fails here too"
                )
            }
        } catch {
            try? await withDeadline(seconds: 60, "runc pod override stop after failure") { try await pod.stop() }
            throw error
        }
    }

    // Twin of testRuncProcessTty, and the reason LinuxPod applies
    // LinuxContainer.mountsForRuntime. runc cannot create /dev/console on the
    // kernel-wide devtmpfs instance, so without the pod's /dev rewrite this
    // container fails to start rather than reporting the wrong TERM.
    func testRuncPodProcessTty() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-pod-process-tty"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm, vm: .default) { config in
            config.ociRuntimePath = runtime
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["env"]
            config.process.terminal = true
            config.process.stdout = buffer
        }

        do {
            try await withDeadline(seconds: 60, "runc pod tty create") { try await pod.create() }
            try await withDeadline(seconds: 60, "runc pod tty start container") { try await pod.startContainer("container1") }
            let status = try await withDeadline(seconds: 60, "runc pod tty env to exit") { try await pod.waitContainer("container1") }
            try await withDeadline(seconds: 60, "runc pod tty stop") { try await pod.stop() }

            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0: \(output)")
            }
            guard output.contains("TERM=xterm") else {
                throw IntegrationError.assert(msg: "expected TERM=xterm in the environment, got: \(output)")
            }
        } catch {
            try? await withDeadline(seconds: 60, "runc pod tty stop after failure") { try await pod.stop() }
            throw error
        }
    }

    /// Read one container's probe output, failing with the output attached
    /// rather than with a bare parse error.
    private static func requireSeccompProbe(_ buffer: BufferWriter, status: ExitStatus, container: String) throws -> SeccompProbeResult {
        let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "seccomp probe in \(container) failed (exit \(status.exitCode)): \(output)")
        }
        guard let parsed = Self.parseSeccompStatus(output) else {
            throw IntegrationError.assert(msg: "could not read Seccomp/Seccomp_filters from \(container): \(output)")
        }
        return parsed
    }

    // Twin of testPodSharedPIDNamespace. This is the pod's one spec difference
    // in kind rather than in values: with a shared namespace the containers get
    // `LinuxNamespace(type: .pid, path: /proc/<pausePID>/ns/pid)`, so runc joins
    // an existing namespace instead of creating one. The pause process that owns
    // it is launched by vmexec either way.
    func testRuncPodSharedPIDNamespace() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-pod-shared-pid-namespace"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm, vm: .default) { config in
            config.ociRuntimePath = runtime
            config.bootLog = bs.bootLog
            config.shareProcessNamespace = true
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/sleep", "300"]
        }

        let psBuffer = BufferWriter()
        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/sh", "-c", "ps aux | grep 'sleep 300' | grep -v grep"]
            config.process.stdout = psBuffer
        }

        do {
            try await withDeadline(seconds: 60, "runc pod shared pid create") { try await pod.create() }
            try await withDeadline(seconds: 60, "runc pod shared pid start container1") { try await pod.startContainer("container1") }
            try await Task.sleep(for: .milliseconds(100))

            try await withDeadline(seconds: 60, "runc pod shared pid start container2") { try await pod.startContainer("container2") }
            let status = try await withDeadline(seconds: 60, "runc pod shared pid container2 to exit") {
                try await pod.waitContainer("container2")
            }

            try await withDeadline(seconds: 60, "runc pod shared pid kill container1") { try await pod.killContainer("container1", signal: .kill) }
            _ = try await withDeadline(seconds: 60, "runc pod shared pid container1 to exit") { try await pod.waitContainer("container1") }
            try await withDeadline(seconds: 60, "runc pod shared pid stop") { try await pod.stop() }

            let output = String(data: psBuffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "container2 should have found the sleep process (status: \(status)): \(output)")
            }
            guard output.contains("sleep 300") else {
                throw IntegrationError.assert(msg: "ps output should contain 'sleep 300', got: '\(output)'")
            }
        } catch {
            try? await withDeadline(seconds: 60, "runc pod shared pid stop after failure") { try await pod.stop() }
            throw error
        }
    }
}
