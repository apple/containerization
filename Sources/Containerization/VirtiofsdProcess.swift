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

#if os(Linux)
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// A managed `virtiofsd` subprocess serving a single shared directory.
///
/// One `VirtiofsdProcess` per virtio-fs share. Cloud Hypervisor connects to
/// the published UDS via its `FsConfig.socket` field. Lifecycle mirrors
/// `CHProcess`: spawn + wait-for-socket on `start()`, SIGTERM/SIGKILL on
/// `terminate()`.
final class VirtiofsdProcess: Sendable {
    struct Config: Sendable {
        let binary: URL
        let socketPath: URL
        let sharedDir: URL
        let readonly: Bool
    }

    private struct State {
        var command: Command?
        var exitTask: Task<Void, Never>?
    }

    private let config: Config
    private let logger: Logger?
    private let state: Mutex<State>

    init(config: Config, logger: Logger?) {
        self.config = config
        self.logger = logger
        self.state = Mutex(State(command: nil, exitTask: nil))
    }

    /// Spawn virtiofsd and wait for its UDS to accept connections.
    func start() async throws {
        var arguments = [
            "--socket-path", config.socketPath.path,
            "--shared-dir", config.sharedDir.path,
        ]
        if SandboxOverrides.virtiofsdSandboxDisabled {
            // virtiofsd defaults to `--sandbox namespace`, which sets up a
            // userns + pivot_root + seccomp filter. Inside apple/container's
            // --virtualization dev container the default seccomp profile
            // SIGSYS-kills processes that hit unfiltered syscalls (same
            // reason CH runs with `--seccomp false`). `--sandbox none`
            // skips both userns setup and seccomp; safe inside the per-VM
            // dev container only. Opt-in via
            // CONTAINERIZATION_NO_VIRTIOFSD_SANDBOX=1.
            logger?.warning(
                "virtiofsd launching with --sandbox none (CONTAINERIZATION_NO_VIRTIOFSD_SANDBOX=1) — userns/pivot_root/seccomp setup disabled"
            )
            arguments.append(contentsOf: ["--sandbox", "none"])
        }
        if config.readonly {
            arguments.append("--readonly")
        }

        var command = Command(
            config.binary.path,
            arguments: arguments,
            environment: ChildEnvironment.minimal()
        )
        // Inherit stderr so virtiofsd's startup logs surface in the host's
        // log stream rather than vanishing into /dev/null (Command's default).
        command.stderr = FileHandle.standardError
        // Same rationale as CHProcess: keep virtiofsd out of the parent's
        // controlling-TTY signal group so Ctrl-C doesn't kill it before our
        // own terminate() ladder runs.
        command.attrs.setsid = true
        do {
            try command.start()
        } catch {
            throw error
        }

        let exitTask = Task<Void, Never>.detached { [command, logger] in
            do {
                _ = try command.wait()
            } catch {
                logger?.error("virtiofsd wait failed: \(error)")
            }
        }

        state.withLock {
            $0.command = command
            $0.exitTask = exitTask
        }

        try await waitForSocket()
    }

    /// SIGTERM → grace window → SIGKILL. Returns once virtiofsd is reaped.
    func terminate(graceSeconds: UInt32) async {
        guard let command = state.withLock({ $0.command }) else { return }

        _ = command.kill(SIGTERM)

        do {
            try await Timeout.run(for: .seconds(Int(graceSeconds))) {
                await self.waitForExit()
            }
        } catch {
            logger?.warning("virtiofsd did not exit within \(graceSeconds)s, sending SIGKILL")
            _ = command.kill(SIGKILL)
            await waitForExit()
        }
    }

    // MARK: - Private helpers

    private static let socketDeadline: Duration = .seconds(10)
    private static let socketPollInterval: Duration = .milliseconds(50)

    private func waitForExit() async {
        guard let task = state.withLock({ $0.exitTask }) else { return }
        await task.value
    }

    private func waitForSocket() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: Self.socketDeadline)

        while clock.now < deadline {
            if Self.isSocketReady(at: config.socketPath) {
                let elapsed = clock.now - started
                logger?.debug("virtiofsd socket bound in \(elapsed) at \(config.socketPath.path)")
                return
            }
            try? await Task.sleep(for: Self.socketPollInterval)
        }

        // Capture diagnostic state before terminating.
        let fm = FileManager.default
        let socketExists = fm.fileExists(atPath: config.socketPath.path)
        let parentExists = fm.fileExists(atPath: config.socketPath.deletingLastPathComponent().path)
        let sharedExists = fm.fileExists(atPath: config.sharedDir.path)
        let detail = "socketExists=\(socketExists) parentDirExists=\(parentExists) sharedDirExists=\(sharedExists)"

        await terminate(graceSeconds: 5)
        throw ContainerizationError(
            .timeout,
            message: "virtiofsd socket not connectable at \(config.socketPath.path) within \(Self.socketDeadline) [\(detail)]"
        )
    }

    private static func isSocketReady(at url: URL) -> Bool {
        // Only check that the socket file exists. Do NOT connect — virtiofsd
        // runs in vhost-user mode where the first incoming connection is
        // treated as the VMM (cloud-hypervisor); when that connection closes,
        // virtiofsd exits. A connect-then-close readiness probe therefore
        // kills virtiofsd before CH ever gets to it, leaving CH's vm.boot
        // failing with "vhost-user: can't connect to peer: No such file
        // or directory".
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

}
#endif
