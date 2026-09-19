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
import Foundation

// Integration tests for the runc-backed container path, selected with
// `config.ociRuntimePath`. Each is a twin of a vmexec test in
// ContainerTests.swift and should stay behaviourally identical to it.
extension IntegrationSuite {
    /// Guest path of the runc binary staged by `make init`, or a skip when runc
    /// was never fetched. Reads the same `bin/runc-<arch>` the Makefile's
    /// `$(wildcard $(RUNC_BIN))` stages on, and must stay in sync with it.
    static func requireRunc() throws -> String {
        #if arch(arm64)
        let hostBinary = "runc-arm64"
        #else
        let hostBinary = "runc-x86_64"
        #endif
        guard FileManager.default.fileExists(atPath: Self.binPath(name: hostBinary).path) else {
            throw SkipTest(reason: "bin/\(hostBinary) missing; run 'make fetch-runc && make init'")
        }
        return "/sbin/runc"
    }

    func testRuncProcessTrue() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-process-true"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["/bin/true"]
            config.memoryInBytes = 250_000_000
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc /bin/true container create") {
                try await container.create()
            }
            try await withDeadline(seconds: 60, "runc /bin/true container start") {
                try await container.start()
            }

            let status = try await withDeadline(seconds: 60, "runc /bin/true to exit") {
                try await container.wait()
            }
            // `stop()` reaches `runc delete --force`, the same class of call the
            // output-capture fix hardens, so it gets a deadline like the rest.
            try await withDeadline(seconds: 60, "runc /bin/true container stop") {
                try await container.stop()
            }

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }
        } catch {
            // Best-effort teardown: a timeout would otherwise throw with the VM
            // still running, and the next test's bootstrap reaper unlinks its
            // rootfs clones underneath it.
            try? await withDeadline(seconds: 60, "runc /bin/true container stop after failure") {
                try await container.stop()
            }
            throw error
        }
    }

    func testRuncProcessFalse() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-process-false"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["/bin/false"]
            config.memoryInBytes = 250_000_000
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc /bin/false container create") {
                try await container.create()
            }
            try await withDeadline(seconds: 60, "runc /bin/false container start") {
                try await container.start()
            }

            let status = try await withDeadline(seconds: 60, "runc /bin/false to exit") {
                try await container.wait()
            }
            // `stop()` reaches `runc delete --force`, the same class of call the
            // output-capture fix hardens, so it gets a deadline like the rest.
            try await withDeadline(seconds: 60, "runc /bin/false container stop") {
                try await container.stop()
            }

            guard status.exitCode == 1 else {
                throw IntegrationError.assert(msg: "process status \(status) != 1")
            }
        } catch {
            // Best-effort teardown: a timeout would otherwise throw with the VM
            // still running, and the next test's bootstrap reaper unlinks its
            // rootfs clones underneath it.
            try? await withDeadline(seconds: 60, "runc /bin/false container stop after failure") {
                try await container.stop()
            }
            throw error
        }
    }

    func testRuncContainerStatistics() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-container-statistics"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["sleep", "infinity"]
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc statistics container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc statistics container start") { try await container.start() }

            // vminitd reads /container/<id> via its own Cgroup2Manager while runc
            // places the init process from spec.linux.cgroupsPath. Non-zero
            // counters prove the two agree.
            let stats = try await container.statistics()

            guard let process = stats.process, process.current > 0 else {
                throw IntegrationError.assert(msg: "process count should be > 0, got \(stats.process?.current ?? 0)")
            }
            guard let memory = stats.memory, memory.usageBytes > 0 else {
                throw IntegrationError.assert(msg: "memory usage should be > 0, got \(stats.memory?.usageBytes ?? 0)")
            }

            try await container.kill(.kill)
            _ = try await withDeadline(seconds: 60, "runc statistics container wait") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc statistics container stop") { try await container.stop() }
        } catch {
            try? await withDeadline(seconds: 30, "runc statistics cleanup") { try await container.stop() }
            throw error
        }
    }

    func testRuncContainerKillAndStop() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-container-kill-and-stop"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["sleep", "infinity"]
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc kill container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc kill container start") { try await container.start() }

            try await container.kill(.kill)
            let status = try await withDeadline(seconds: 60, "runc sleep to die on SIGKILL") { try await container.wait() }

            // 137 == 128 + SIGKILL. Anything else means the signal did not reach
            // the container init through `runc kill`.
            guard status.exitCode == 137 else {
                throw IntegrationError.assert(msg: "expected exit 137 from SIGKILL, got \(status.exitCode)")
            }

            // stop() drives delete(), which is where cgroup teardown runs.
            try await withDeadline(seconds: 60, "runc container teardown") { try await container.stop() }
        } catch {
            try? await withDeadline(seconds: 30, "runc kill cleanup") { try await container.stop() }
            throw error
        }
    }

    /// Where `bootstrap(id)` will point the guest's serial console, with any
    /// previous run's file removed — it is opened in append mode, and the VMM
    /// does not open it until the VM boots.
    private func resetBootLog(id: String) -> URL {
        let path = URL(filePath: self.bootlogDir).appendingPathComponent("\(id).log")
        try? FileManager.default.removeItem(at: path)
        return path
    }

    /// The guest's log lines. vminitd logs to the serial console, so this is
    /// where the guest says which code path it took. Read after `stop()`, so the
    /// VM has flushed.
    private func bootLogLines(at path: URL) throws -> [String] {
        let data = try Data(contentsOf: path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to decode boot log at \(path.path) as UTF8")
        }
        return text.split(separator: "\n").map(String.init)
    }

    /// Assert that `id`'s exec went through `RuncExecProcess` rather than
    /// falling back to vmexec's `ManagedProcess`, and that it did not hit the
    /// path where an exit was reaped with no status left to claim.
    ///
    /// Both are log assertions: neither has an observable behavioural
    /// difference in this configuration.
    private func assertRuncExec(execID: String, in lines: [String]) throws {
        let startSentinel = "starting runc exec process"
        guard lines.contains(where: { $0.contains(startSentinel) && $0.contains(execID) }) else {
            throw IntegrationError.assert(
                msg: "expected the guest to log '\(startSentinel)' for exec '\(execID)'; the exec did not go through runc"
            )
        }

        // A synthesized status is a real exit code to the host, so only the log
        // can tell it apart from the process's own.
        let lostSentinel = "runc exec was reaped with no exit status to claim"
        if let lost = lines.first(where: { $0.contains(lostSentinel) && $0.contains(execID) }) {
            throw IntegrationError.assert(msg: "exec '\(execID)' lost its exit status and had one synthesized: \(lost)")
        }

        // Either attach-failure path means the relays were not wired up, which
        // costs the exec's output and (before it was fixed) leaked its vsock fds.
        if let attachFailure = lines.first(where: { $0.contains("failed to attach I/O") && $0.contains(execID) }) {
            throw IntegrationError.assert(msg: "exec '\(execID)' failed to attach I/O: \(attachFailure)")
        }
    }

    /// How many of `lines` are the claim path's sentinel -- the exec was reaped
    /// before `RuncExecProcess` recorded its pid. Diagnostic only; see
    /// `testRuncContainerExecFastExit` for why no test requires it.
    private func claimPathCount(in lines: [String]) -> Int {
        lines.filter { $0.contains("runc exec exited before its pid was recorded") }.count
    }

    func testRuncContainerExec() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-container-exec"

        // Asserts the exec lands in the container: same namespaces as the init,
        // and a member of the same cgroup. It cannot distinguish a runc-backed
        // exec from a vmexec-backed one -- both converge on the same observable
        // state -- so the code-path assertion is the boot-log check below.
        let probe = """
            exec 2>&1
            set -u
            fail=0
            for ns in ipc uts mnt pid cgroup; do
                mine=$(readlink /proc/self/ns/$ns)
                init=$(readlink /proc/1/ns/$ns)
                if [ "$mine" != "$init" ]; then
                    echo "NS-FAIL: $ns exec=$mine init=$init"
                    fail=1
                fi
            done
            # Comparing /proc/self/cgroup against /proc/1/cgroup proves nothing:
            # the container has its own cgroup namespace, so both sides read
            # "0::/" wherever the exec actually landed. Assert membership
            # directly instead -- at the cgroup-namespace root,
            # /sys/fs/cgroup/cgroup.procs lists the container cgroup's pids,
            # translated into the container's pid namespace. Requiring both the
            # exec and pid 1 catches an exec placed outside the cgroup.
            procs=$(cat /sys/fs/cgroup/cgroup.procs | tr '\\n' ' ')
            for want in $$ 1; do
                case " $procs " in
                    *" $want "*) ;;
                    *)
                        echo "CGROUP-FAIL: pid $want not in [$procs]"
                        fail=1
                        ;;
                esac
            done
            # The control for testRuncContainerExecSeccompDefault: this
            # container has no profile, so its execs must come out unfiltered.
            # Without it, "the exec is filtered" over there could just mean runc
            # always installs something on a setns-init.
            seccomp=$(grep '^Seccomp:' /proc/self/status | tr -d ' \\t')
            if [ "$seccomp" != "Seccomp:0" ]; then
                echo "SECCOMP-FAIL: expected no filter, got [$seccomp]"
                fail=1
            fi
            [ "$fail" -eq 0 ] || exit 1
            echo "EXEC-OK"
            """

        let bs = try await bootstrap(id)
        let bootLogPath = self.resetBootLog(id: id)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["/bin/sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc exec container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc exec container start") { try await container.start() }

            let buffer = BufferWriter()
            let exec = try await container.exec("runc-exec-probe") { config in
                config.arguments = ["/bin/sh", "-c", probe]
                config.stdout = buffer
            }

            try await withDeadline(seconds: 60, "runc exec probe start") { try await exec.start() }
            let status = try await withDeadline(seconds: 60, "runc exec probe to exit") { try await exec.wait() }
            try await exec.delete()

            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "runc exec probe failed (exit \(status.exitCode)): \(output)")
            }
            guard output.contains("EXEC-OK") else {
                throw IntegrationError.assert(msg: "expected EXEC-OK sentinel, got: \(output)")
            }

            try await container.kill(.kill)
            _ = try await withDeadline(seconds: 60, "runc exec container wait") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc exec container stop") { try await container.stop() }

            // Asserts which code path ran, not a behavioural difference -- there
            // isn't one to observe today (see the probe comment above).
            try self.assertRuncExec(execID: "runc-exec-probe", in: try self.bootLogLines(at: bootLogPath))
        } catch {
            try? await withDeadline(seconds: 30, "runc exec cleanup") { try await container.stop() }
            throw error
        }
    }

    // Twin of testProcessEchoHi. The runc create path wires stdio differently
    // from vmexec, so this checks that a captured stdout still reaches the host
    // over the vsock relay.
    func testRuncProcessEchoHi() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-process-echo-hi"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["/bin/echo", "hi"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc echo hi container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc echo hi container start") { try await container.start() }

            let status = try await withDeadline(seconds: 60, "runc echo hi to exit") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc echo hi container stop") { try await container.stop() }

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard output == "hi\n" else {
                throw IntegrationError.assert(msg: "expected stdout 'hi\\n', got '\(output)'")
            }
        } catch {
            try? await withDeadline(seconds: 30, "runc echo hi cleanup") { try await container.stop() }
            throw error
        }
    }

    // Twin of testProcessStdin. Exercises the other half of the rewired create
    // path: a configured stdin has to become a real pipe (not /dev/null) and
    // then be closed, or `cat` never sees EOF and the container never exits.
    func testRuncProcessStdin() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-process-stdin"

        let expected = "Hello from test"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["cat"]
            config.process.stdin = StdinBuffer(data: Data(expected.utf8))
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc stdin container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc stdin container start") { try await container.start() }

            // A stdin that is never closed hangs `cat` here rather than at any
            // later call, which is precisely what the deadline is for.
            let status = try await withDeadline(seconds: 60, "runc cat to exit on stdin EOF") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc stdin container stop") { try await container.stop() }

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard output == expected else {
                throw IntegrationError.assert(msg: "expected stdout '\(expected)', got '\(output)'")
            }
        } catch {
            try? await withDeadline(seconds: 30, "runc stdin cleanup") { try await container.stop() }
            throw error
        }
    }

    // Twin of testProcessTtyEnvvar, and the only coverage of the console-socket
    // path: with terminal = true runc sends the PTY master over a unix socket
    // (ConsoleSocket) as an SCM_RIGHTS fd, which RuncTerminalIO then relays.
    func testRuncProcessTty() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-process-tty"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["env"]
            config.process.terminal = true
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc tty container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc tty container start") { try await container.start() }

            let status = try await withDeadline(seconds: 60, "runc tty env to exit") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc tty container stop") { try await container.stop() }

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard output.contains("TERM=xterm") else {
                throw IntegrationError.assert(msg: "expected TERM=xterm in the environment, got: \(output)")
            }
        } catch {
            try? await withDeadline(seconds: 30, "runc tty cleanup") { try await container.stop() }
            throw error
        }
    }

    // A short-lived exec is the case the parked-exit buffer exists for: with
    // --detach, runc returns only once the process is already running, so
    // /bin/true can be reaped before RuncExecProcess has recorded its pid.
    //
    // Asserts that each exec went through RuncExecProcess, delivered its stdout,
    // exited 0, and neither lost its exit status nor failed to attach relays.
    // Which branch of `RuncExecProcess.start()` ran is a scheduling race the
    // suite cannot force, and the claim path is the minority outcome (~9-26% of
    // execs in recorded runs), so it is not asserted — the iteration count buys
    // the odds of catching a regression and the deadlines keep a hang from
    // wedging the suite.
    func testRuncContainerExecFastExit() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-container-exec-fast-exit"

        let bs = try await bootstrap(id)
        let bootLogPath = self.resetBootLog(id: id)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["/bin/sleep", "100"]
            config.bootLog = bs.bootLog
        }

        let execCount = 10

        do {
            try await withDeadline(seconds: 60, "runc fast-exec container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc fast-exec container start") { try await container.start() }

            for i in 0..<execCount {
                let buffer = BufferWriter()
                let exec = try await container.exec("fast-\(i)") { config in
                    config.arguments = ["/bin/echo", "fast-\(i)"]
                    config.stdout = buffer
                }
                try await withDeadline(seconds: 60, "fast exec \(i) start") { try await exec.start() }
                let status = try await withDeadline(seconds: 60, "fast exec \(i) to exit") { try await exec.wait() }
                try await exec.delete()

                guard status.exitCode == 0 else {
                    throw IntegrationError.assert(msg: "fast exec \(i) status \(status) != 0")
                }

                let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
                guard output == "fast-\(i)\n" else {
                    throw IntegrationError.assert(msg: "expected fast exec \(i) stdout 'fast-\(i)\\n', got '\(output)'")
                }
            }

            try await container.kill(.kill)
            _ = try await withDeadline(seconds: 60, "runc fast-exec container wait") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc fast-exec container stop") { try await container.stop() }

            let lines = try self.bootLogLines(at: bootLogPath)
            for i in 0..<execCount {
                try self.assertRuncExec(execID: "fast-\(i)", in: lines)
            }
            // Not an assertion -- see the comment above. Recorded so a run's log
            // says how much claim-path coverage it happened to get.
            print("  \(id): the claim path ran for \(self.claimPathCount(in: lines))/\(execCount) execs")
        } catch {
            try? await withDeadline(seconds: 30, "runc fast-exec cleanup") { try await container.stop() }
            throw error
        }
    }

    // The two halves of the runc exec path that nothing else covers together: a
    // console socket *and* an exec short enough to be reaped before its pid is
    // recorded. testRuncProcessTty covers a terminal on the init path and
    // testRuncContainerExecFastExit a fast exec with plain pipes.
    //
    // The combination is opportunistic rather than asserted -- which branch of
    // `start()` runs is the same scheduling race as in that test. Asserted every
    // run: the console socket (fd passing, pty relay, output delivered) and that
    // the exec went through runc.
    func testRuncContainerExecTerminal() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-container-exec-terminal"

        let bs = try await bootstrap(id)
        let bootLogPath = self.resetBootLog(id: id)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["/bin/sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc tty-exec container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc tty-exec container start") { try await container.start() }

            let buffer = BufferWriter()
            let exec = try await container.exec("runc-exec-tty") { config in
                config.arguments = ["/bin/echo", "hi"]
                config.terminal = true
                config.stdout = buffer
            }

            try await withDeadline(seconds: 60, "runc tty exec start") { try await exec.start() }
            let status = try await withDeadline(seconds: 60, "runc tty exec to exit") { try await exec.wait() }
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "runc tty exec status \(status) != 0")
            }

            // A pty is on the other end, so ONLCR turns the newline into CRLF.
            // Match the payload rather than the exact bytes.
            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard output.contains("hi") else {
                throw IntegrationError.assert(msg: "expected 'hi' from the terminal exec, got '\(output)'")
            }

            try await container.kill(.kill)
            _ = try await withDeadline(seconds: 60, "runc tty-exec container wait") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc tty-exec container stop") { try await container.stop() }

            try self.assertRuncExec(execID: "runc-exec-tty", in: try self.bootLogLines(at: bootLogPath))
        } catch {
            try? await withDeadline(seconds: 30, "runc tty-exec cleanup") { try await container.stop() }
            throw error
        }
    }

    // /proc/<pid>/status reports the calling thread's seccomp mode: `Seccomp: 0`
    // is no filter, `Seccomp: 2` is SECCOMP_MODE_FILTER, and `Seccomp_filters`
    // counts them. Filters are inherited across fork and exec, so a grandchild
    // of the container init gives the same answer as the init.
    //
    // `unshare -U` is the behavioural half. Creating a user namespace needs no
    // capability, so it succeeds unfiltered; under the default profile
    // `unshare` is in containerd's CAP_SYS_ADMIN group only and the `clone`
    // argument filter rejects CLONE_NEWUSER, so both routes return EPERM. That
    // makes it a seccomp differential rather than a capability one -- the
    // paired tests below differ only in `seccompProfile`.
    //
    // A missing applet gets its own sentinel: 127 would otherwise satisfy
    // "non-zero" and leave the behavioural check exercising nothing.
    private static let seccompStatusProbe = """
        exec 2>&1
        grep '^Seccomp' /proc/self/status
        if command -v unshare >/dev/null 2>&1; then
            usernsOut=$(unshare -U /bin/true 2>&1)
            usernsRC=$?
            echo "USERNS-RC:$usernsRC"
            echo "USERNS-ERR:$(echo "$usernsOut" | tr '\\n' ' ')"
        else
            echo "USERNS-RC:missing"
        fi
        """

    private struct SeccompProbeResult {
        /// `/proc/self/status`'s `Seccomp:` field. 0 is no filter, 2 is
        /// SECCOMP_MODE_FILTER.
        let mode: String
        /// `/proc/self/status`'s `Seccomp_filters:` field.
        let filters: Int
        /// `unshare -U`'s exit status, or `nil` when the guest has no `unshare`
        /// at all and the probe could not run it.
        let usernsRC: Int?
        /// Whatever `unshare -U` wrote to stderr, on one line.
        let usernsError: String
    }

    /// Parse the probe's `Seccomp:` / `Seccomp_filters:` / `USERNS-*` lines.
    private static func parseSeccompStatus(_ output: String) -> SeccompProbeResult? {
        var mode: String?
        var filters: Int?
        var usernsRC: String?
        var usernsError = ""
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Seccomp":
                mode = value
            case "Seccomp_filters":
                filters = Int(value)
            case "USERNS-RC":
                usernsRC = value
            case "USERNS-ERR":
                usernsError = value
            default:
                continue
            }
        }
        // A missing USERNS-RC line means the probe itself did not run to
        // completion, which is a different failure from `unshare` being absent
        // -- that reports the `missing` sentinel, and surfaces as a nil rc.
        guard let mode, let filters, let usernsRC else {
            return nil
        }
        return SeccompProbeResult(
            mode: mode,
            filters: filters,
            usernsRC: Int(usernsRC),
            usernsError: usernsError
        )
    }

    func testRuncProcessSeccompDefault() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-process-seccomp-default"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.seccompProfile = .default
            config.process.arguments = ["/bin/sh", "-c", Self.seccompStatusProbe]
            config.process.stdout = buffer
            config.memoryInBytes = 250_000_000
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc seccomp container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc seccomp container start") { try await container.start() }

            let status = try await withDeadline(seconds: 60, "runc seccomp probe to exit") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc seccomp container stop") { try await container.stop() }

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
            // The behavioural half. See the probe's comment for why this is not
            // a capability denial.
            guard let usernsRC = parsed.usernsRC else {
                throw IntegrationError.assert(
                    msg: "the guest image has no 'unshare', so the behavioural half of this test exercised nothing; "
                        + "restore the applet or replace the probe: \(output)"
                )
            }
            // Assert the specific denial: both busybox and util-linux exit 1
            // after a failed unshare(2), while 127/126 mean a missing or
            // non-executable binary. The profile's default action is
            // SCMP_ACT_ERRNO with no errnoRet, i.e. EPERM.
            guard usernsRC == 1, parsed.usernsError.lowercased().contains("not permitted") else {
                throw IntegrationError.assert(
                    msg: "expected 'unshare -U' to be denied with EPERM under the default profile, "
                        + "got rc \(usernsRC) and '\(parsed.usernsError)' in: \(output)"
                )
            }
        } catch {
            try? await withDeadline(seconds: 30, "runc seccomp cleanup") { try await container.stop() }
            throw error
        }
    }

    // The control for testRuncProcessSeccompDefault: the same container and
    // probe with `seccompProfile` left at `.unconfined`.
    func testRuncProcessSeccompDisabledByDefault() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-process-seccomp-none"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.process.arguments = ["/bin/sh", "-c", Self.seccompStatusProbe]
            config.process.stdout = buffer
            config.memoryInBytes = 250_000_000
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc no-seccomp container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc no-seccomp container start") { try await container.start() }

            let status = try await withDeadline(seconds: 60, "runc no-seccomp probe to exit") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc no-seccomp container stop") { try await container.stop() }

            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "seccomp probe failed (exit \(status.exitCode)): \(output)")
            }
            guard let parsed = Self.parseSeccompStatus(output) else {
                throw IntegrationError.assert(msg: "could not read Seccomp/Seccomp_filters from /proc/self/status: \(output)")
            }
            guard parsed.mode == "0", parsed.filters == 0 else {
                throw IntegrationError.assert(
                    msg: "expected no filter without seccompProfile, got 'Seccomp: \(parsed.mode)' / 'Seccomp_filters: \(parsed.filters)' in: \(output)"
                )
            }
            // Control for the behavioural probe: it has to succeed here, or its
            // failure in the positive test says nothing about seccomp. A failure
            // here most likely means unprivileged user namespaces are gone from
            // the guest kernel and the probe needs replacing.
            guard parsed.usernsRC == 0 else {
                let rc = parsed.usernsRC.map(String.init) ?? "no 'unshare' in the image"
                throw IntegrationError.assert(
                    msg: "expected 'unshare -U' to succeed without a seccomp profile (rc \(rc), '\(parsed.usernsError)'); "
                        + "the probe cannot discriminate if it fails here too: \(output)"
                )
            }
        } catch {
            try? await withDeadline(seconds: 30, "runc no-seccomp cleanup") { try await container.stop() }
            throw error
        }
    }

    // The exec half. `runc exec` is a different code path from `runc run` --
    // linuxSetnsInit rather than linuxStandardInit -- with its own ordering of
    // seccomp installation against capability dropping, and `noNewPrivileges`
    // is false here, which selects the branch that ordering matters to.
    //
    // The host leaves the profile out of an exec's spec, so inheritance from
    // the container's saved config.json is the only way the filter can be here.
    // testRuncContainerExec -- an exec in an unprofiled container -- is the
    // control, and asserts `Seccomp: 0`.
    func testRuncContainerExecSeccompDefault() async throws {
        let runtime = try Self.requireRunc()
        let id = "test-runc-container-exec-seccomp-default"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            config.seccompProfile = .default
            config.process.arguments = ["/bin/sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "runc exec seccomp container create") { try await container.create() }
            try await withDeadline(seconds: 60, "runc exec seccomp container start") { try await container.start() }

            let buffer = BufferWriter()
            let exec = try await container.exec("runc-exec-seccomp-probe") { config in
                config.arguments = ["/bin/sh", "-c", Self.seccompStatusProbe]
                config.stdout = buffer
            }
            try await withDeadline(seconds: 60, "runc exec seccomp probe start") { try await exec.start() }
            let status = try await withDeadline(seconds: 60, "runc exec seccomp probe to exit") { try await exec.wait() }
            try await exec.delete()

            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec seccomp probe failed (exit \(status.exitCode)): \(output)")
            }
            guard let parsed = Self.parseSeccompStatus(output) else {
                throw IntegrationError.assert(msg: "could not read Seccomp/Seccomp_filters from the exec's /proc/self/status: \(output)")
            }
            // 2 == SECCOMP_MODE_FILTER, on the exec'd process itself.
            guard parsed.mode == "2" else {
                throw IntegrationError.assert(
                    msg: "expected 'Seccomp: 2' in an exec of a profiled container, got 'Seccomp: \(parsed.mode)' in: \(output)"
                )
            }
            guard parsed.filters > 0 else {
                throw IntegrationError.assert(
                    msg: "expected a non-zero Seccomp_filters in an exec of a profiled container, got \(parsed.filters) in: \(output)"
                )
            }
            // And that the filter is the profile rather than an empty one: same
            // denial, same reasoning as the init-process test.
            guard let usernsRC = parsed.usernsRC else {
                throw IntegrationError.assert(
                    msg: "the guest image has no 'unshare', so the behavioural half of this test exercised nothing: \(output)"
                )
            }
            guard usernsRC == 1, parsed.usernsError.lowercased().contains("not permitted") else {
                throw IntegrationError.assert(
                    msg: "expected the exec's 'unshare -U' to be denied with EPERM under the container's profile, "
                        + "got rc \(usernsRC) and '\(parsed.usernsError)' in: \(output)"
                )
            }

            try await container.kill(.kill)
            _ = try await withDeadline(seconds: 60, "runc exec seccomp container wait") { try await container.wait() }
            try await withDeadline(seconds: 60, "runc exec seccomp container stop") { try await container.stop() }
        } catch {
            try? await withDeadline(seconds: 30, "runc exec seccomp cleanup") { try await container.stop() }
            throw error
        }
    }

    // A caller-supplied profile, read the way a caller would supply one: JSON
    // through `LinuxSeccomp.decode(from:)`, so this covers the loader and the
    // tolerant decoder as well as the `Configuration` knob. Minimal on purpose
    // -- no `architectures`, `flags` or `args`.
    //
    // Allow-by-default with one rule denying `mkdir` / `mkdirat` makes it a
    // real differential: nothing else in the container is restricted. Both
    // names appear because aarch64 has no `mkdir` syscall; runc skips a name
    // libseccomp cannot resolve on the running architecture.
    private static let customSeccompProfileJSON = """
        {
          "defaultAction": "SCMP_ACT_ALLOW",
          "syscalls": [
            { "names": ["mkdir", "mkdirat"], "action": "SCMP_ACT_ERRNO", "errnoRet": 13 }
          ]
        }
        """

    // Reports the filter mode, then tries the denied syscall and an allowed one
    // in the same directory. `touch` is the within-container control: an
    // unwritable rootfs would fail `mkdir` with EROFS in both containers. The
    // errno text is kept because the assertion is on which failure happened --
    // the profile asks for EACCES, distinct from a capability check's EPERM.
    private static let mkdirSeccompProbe = """
        exec 2>&1
        grep '^Seccomp:' /proc/self/status
        mkdirOut=$(mkdir /cz-seccomp-mkdir-probe 2>&1)
        echo "MKDIR-RC:$?"
        echo "MKDIR-ERR:$(echo "$mkdirOut" | tr '\\n' ' ')"
        touchOut=$(touch /cz-seccomp-touch-probe 2>&1)
        echo "TOUCH-RC:$?"
        echo "TOUCH-ERR:$(echo "$touchOut" | tr '\\n' ' ')"
        """

    private struct MkdirProbeResult {
        /// `/proc/self/status`'s `Seccomp:` field. 0 is no filter, 2 is
        /// SECCOMP_MODE_FILTER.
        let mode: String
        let mkdirRC: Int
        let mkdirError: String
        let touchRC: Int
        let touchError: String
    }

    private static func parseMkdirProbe(_ output: String) -> MkdirProbeResult? {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let mode = fields["Seccomp"],
            let mkdirRC = fields["MKDIR-RC"].flatMap(Int.init),
            let touchRC = fields["TOUCH-RC"].flatMap(Int.init)
        else {
            return nil
        }
        return MkdirProbeResult(
            mode: mode,
            mkdirRC: mkdirRC,
            mkdirError: fields["MKDIR-ERR"] ?? "",
            touchRC: touchRC,
            touchError: fields["TOUCH-ERR"] ?? ""
        )
    }

    /// Runs ``mkdirSeccompProbe`` in a runc-backed container, with or without
    /// the custom profile, and returns what the probe saw.
    private func runMkdirSeccompProbe(id: String, profile: LinuxSeccomp?) async throws -> MkdirProbeResult {
        let runtime = try Self.requireRunc()
        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.ociRuntimePath = runtime
            if let profile {
                config.seccompProfile = .profile(profile)
            }
            config.process.arguments = ["/bin/sh", "-c", Self.mkdirSeccompProbe]
            config.process.stdout = buffer
            config.memoryInBytes = 250_000_000
            config.bootLog = bs.bootLog
        }

        do {
            try await withDeadline(seconds: 60, "\(id) create") { try await container.create() }
            try await withDeadline(seconds: 60, "\(id) start") { try await container.start() }

            let status = try await withDeadline(seconds: 60, "\(id) probe to exit") { try await container.wait() }
            try await withDeadline(seconds: 60, "\(id) stop") { try await container.stop() }

            let output = String(data: buffer.data, encoding: .utf8) ?? "<non-utf8 output>"
            // The probe reports failures rather than propagating them, so a
            // non-zero status means the shell never ran it to the end.
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "\(id) probe failed (exit \(status.exitCode)): \(output)")
            }
            guard let parsed = Self.parseMkdirProbe(output) else {
                throw IntegrationError.assert(msg: "\(id) probe output could not be parsed: \(output)")
            }
            return parsed
        } catch {
            try? await withDeadline(seconds: 30, "\(id) cleanup") { try await container.stop() }
            throw error
        }
    }

    // The differential, in one test: two runc-backed containers identical
    // except that one carries the custom profile. `mkdir` has to fail in that
    // one and succeed in the other.
    func testRuncProcessCustomSeccompProfile() async throws {
        _ = try Self.requireRunc()
        let profile = try LinuxSeccomp.decode(from: Data(Self.customSeccompProfileJSON.utf8))

        let profiled = try await runMkdirSeccompProbe(id: "test-runc-custom-seccomp", profile: profile)

        // 2 == SECCOMP_MODE_FILTER. A profile that never reached runc would read
        // 0 here and take the mkdir assertion below with it.
        guard profiled.mode == "2" else {
            throw IntegrationError.assert(msg: "expected 'Seccomp: 2' with a custom profile, got 'Seccomp: \(profiled.mode)'")
        }
        // The denial and its errno: 13 is the EACCES the profile asks for,
        // which busybox reports as "Permission denied" -- distinct from the
        // "Operation not permitted" of an EPERM from a capability check.
        guard profiled.mkdirRC != 0 else {
            throw IntegrationError.assert(msg: "expected 'mkdir' to be denied under the custom profile, but it succeeded")
        }
        guard profiled.mkdirError.lowercased().contains("permission denied") else {
            throw IntegrationError.assert(
                msg: "expected 'mkdir' to fail with the profile's EACCES, got rc \(profiled.mkdirRC) and '\(profiled.mkdirError)'"
            )
        }
        // Allow-by-default has to still mean allow: a deny-everything filter, or
        // an unwritable rootfs, would satisfy the assertion above too.
        guard profiled.touchRC == 0 else {
            throw IntegrationError.assert(
                msg: "expected 'touch' to succeed under an allow-by-default profile, got rc \(profiled.touchRC) and '\(profiled.touchError)'; "
                    + "the mkdir denial above says nothing if the whole filesystem is unwritable"
            )
        }

        // The control. Same container without the profile: no filter, and mkdir
        // succeeds.
        let unprofiled = try await runMkdirSeccompProbe(id: "test-runc-custom-seccomp-control", profile: nil)

        guard unprofiled.mode == "0" else {
            throw IntegrationError.assert(msg: "expected no filter without a profile, got 'Seccomp: \(unprofiled.mode)'")
        }
        guard unprofiled.mkdirRC == 0 else {
            throw IntegrationError.assert(
                msg: "expected 'mkdir' to succeed without a seccomp profile, got rc \(unprofiled.mkdirRC) and '\(unprofiled.mkdirError)'; "
                    + "the probe cannot discriminate if mkdir fails here too"
            )
        }
        guard unprofiled.touchRC == 0 else {
            throw IntegrationError.assert(
                msg: "expected 'touch' to succeed without a seccomp profile, got rc \(unprofiled.touchRC) and '\(unprofiled.touchError)'"
            )
        }
    }
}
