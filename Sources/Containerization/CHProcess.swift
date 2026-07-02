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

/// A managed `cloud-hypervisor` subprocess.
///
/// Owns spawning the binary with `--api-socket <path>`, attaching stdout/stderr
/// per the supplied `BootLog`, and tearing it down with a SIGTERM/SIGKILL ladder.
/// One `CHProcess` per VM. Not safe to call `start()` more than once.
final class CHProcess: Sendable {
    struct Config: Sendable {
        let binary: URL
        let apiSocketPath: URL
        let bootLog: BootLog?
    }

    enum ExitReason: Sendable, Equatable {
        case exited(Int32)
        case signalled(Int32)
        case unknown
    }

    private struct State {
        var command: Command?
        var bootLogHandle: FileHandle?
        var exitTask: Task<ExitReason, Never>?
    }

    private let config: Config
    private let logger: Logger?
    private let state: Mutex<State>

    init(config: Config, logger: Logger?) {
        self.config = config
        self.logger = logger
        self.state = Mutex(State(command: nil, bootLogHandle: nil, exitTask: nil))
    }

    /// Spawn the cloud-hypervisor binary and wait for its API socket to accept
    /// connections. Throws `ContainerizationError(.timeout, ...)` if the socket
    /// is not connectable within the bounded poll deadline.
    func start() async throws {
        let logHandle = try Self.openBootLogHandle(config.bootLog)
        var arguments = ["--api-socket", config.apiSocketPath.path]
        if SandboxOverrides.chSeccompDisabled {
            // `--seccomp false`: cloud-hypervisor's default seccomp profile
            // SIGSYS-kills the VMM on syscalls it didn't anticipate. Inside
            // apple/container's --virtualization dev container the unix-vsock
            // muxer's accept(2)/connect(2) interactions on per-port UDS files
            // trip the filter and CH dies mid-process-start, surfacing on the
            // host as "Stream unexpectedly closed" on the vminitd gRPC channel.
            // Opt-in via CONTAINERIZATION_NO_CH_SECCOMP=1; default = secure.
            logger?.warning(
                "cloud-hypervisor launching with --seccomp false (CONTAINERIZATION_NO_CH_SECCOMP=1) — VMM seccomp filter disabled"
            )
            arguments.append(contentsOf: ["--seccomp", "false"])
        }
        var command = Command(
            config.binary.path,
            arguments: arguments,
            environment: ChildEnvironment.minimal()
        )
        command.stdout = logHandle
        command.stderr = logHandle
        // Run cloud-hypervisor in its own session. Without setsid, the VMM
        // shares the parent process group and inherits SIGINT/SIGQUIT from
        // the controlling TTY (e.g. Ctrl-C in `cctl run`), dying alongside
        // the parent before our own teardown ladder (terminate → wait) gets
        // a chance to run an orderly shutdown.
        command.attrs.setsid = true

        do {
            try command.start()
        } catch {
            try? logHandle?.close()
            throw error
        }

        let exitTask = Task<ExitReason, Never>.detached { [command, logger] in
            do {
                let status = try command.wait()
                if status >= 128 {
                    return .signalled(status - 128)
                }
                return .exited(status)
            } catch {
                logger?.error("cloud-hypervisor wait failed: \(error)")
                return .unknown
            }
        }

        state.withLock {
            $0.command = command
            $0.bootLogHandle = logHandle
            $0.exitTask = exitTask
        }

        try await waitForAPISocket()
    }

    /// Wait for the subprocess to exit. Resolves with the cached `ExitReason`
    /// once `wait4` has returned. Safe to call any number of times.
    func wait() async -> ExitReason {
        guard let task = state.withLock({ $0.exitTask }) else {
            return .unknown
        }
        return await task.value
    }

    /// Send SIGTERM, then SIGKILL after `graceSeconds` if the process is still
    /// running. Returns once the process has been reaped.
    func terminate(graceSeconds: UInt32) async {
        guard let command = state.withLock({ $0.command }) else { return }

        _ = command.kill(SIGTERM)

        do {
            try await Timeout.run(for: .seconds(Int(graceSeconds))) {
                _ = await self.wait()
            }
        } catch {
            logger?.warning("cloud-hypervisor did not exit within \(graceSeconds)s, sending SIGKILL")
            _ = command.kill(SIGKILL)
            _ = await wait()
        }

        state.withLock {
            try? $0.bootLogHandle?.close()
            $0.bootLogHandle = nil
        }
    }

    // MARK: - Private helpers

    private static let socketDeadline: Duration = .seconds(2)
    private static let socketPollInterval: Duration = .milliseconds(50)

    private func waitForAPISocket() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.socketDeadline)

        while clock.now < deadline {
            if Self.isAPISocketReady(at: config.apiSocketPath) {
                return
            }
            try? await Task.sleep(for: Self.socketPollInterval)
        }

        await terminate(graceSeconds: 5)
        throw ContainerizationError(
            .timeout,
            message: "cloud-hypervisor API socket not connectable at \(config.apiSocketPath.path) within \(Self.socketDeadline)"
        )
    }

    private static func isAPISocketReady(at url: URL) -> Bool {
        guard let unix = try? UnixType(path: url.path) else { return false }
        guard let socket = try? Socket(type: unix) else { return false }
        defer { try? socket.close() }
        do {
            try socket.connect()
            return true
        } catch {
            return false
        }
    }

    private static func openBootLogHandle(_ bootLog: BootLog?) throws -> FileHandle? {
        guard let bootLog else { return nil }
        switch bootLog.base {
        case .file(let path, let append):
            var flags = O_WRONLY | O_CREAT
            flags |= append ? O_APPEND : O_TRUNC
            let fd = open(path.path, flags, 0o644)
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        case .fileHandle(let handle):
            return handle
        }
    }

}
#endif
