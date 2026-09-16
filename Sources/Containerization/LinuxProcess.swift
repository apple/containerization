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

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import Synchronization

/// `LinuxProcess` represents a Linux process and is used to
/// setup and control the full lifecycle for the process.
public final class LinuxProcess: Sendable {
    /// The ID of the process. This is purely metadata for the caller.
    public let id: String

    /// What container owns this process (if any).
    public let owningContainer: String?

    package struct StdioSetup: Sendable {
        let port: UInt32
        let writer: Writer
    }

    package struct StdioReaderSetup {
        let port: UInt32
        let reader: ReaderStream
    }

    package struct Stdio: Sendable {
        let stdin: StdioReaderSetup?
        let stdout: StdioSetup?
        let stderr: StdioSetup?
    }

    private struct StdioHandles: Sendable {
        var stdin: FileHandle?
        var stdout: FileHandle?
        var stderr: FileHandle?

        mutating func close() throws {
            if let stdin {
                try stdin.close()
                stdin.readabilityHandler = nil
                self.stdin = nil
            }
            if let stdout {
                try stdout.close()
                stdout.readabilityHandler = nil
                self.stdout = nil
            }
            if let stderr {
                try stderr.close()
                stderr.readabilityHandler = nil
                self.stderr = nil
            }
        }
    }

    private struct State {
        var spec: ContainerizationOCI.Spec
        var pid: Int32
        var stdio: StdioHandles
        var stdinRelay: Task<(), Never>?
        var ioTracker: IoTracker?
        var deletionTask: Task<Void, Error>?

        struct IoTracker {
            let stream: AsyncStream<Void>
            let cont: AsyncStream<Void>.Continuation
            let configuredStreams: Int
        }
    }

    /// The process ID for the container process. This will be -1
    /// if the process has not been started.
    public var pid: Int32 {
        state.withLock { $0.pid }
    }

    private let state: Mutex<State>
    private let ioSetup: Stdio
    private let agent: any VirtualMachineAgent
    private let vm: any VirtualMachineInstance
    private let ociRuntimePath: String?
    private let logger: Logger?
    private let onDelete: (@Sendable () async -> Void)?

    /// The allocator that `io`'s ports came from. This process gives them
    /// back when it is deleted; see `VsockPortAllocator` for why they can't
    /// simply be abandoned.
    private let portAllocator: VsockPortAllocator

    /// How long to wait for the guest to dial back for each stdio stream.
    /// Defaults to the process-wide `stdioDialBackTimeout`; injectable so
    /// tests don't have to wait it out.
    private let stdioTimeout: UInt32

    init(
        _ id: String,
        containerID: String? = nil,
        spec: Spec,
        io: Stdio,
        portAllocator: VsockPortAllocator,
        ociRuntimePath: String?,
        agent: any VirtualMachineAgent,
        vm: any VirtualMachineInstance,
        logger: Logger?,
        stdioTimeoutSeconds: UInt32 = LinuxProcess.stdioDialBackTimeout,
        onDelete: (@Sendable () async -> Void)? = nil
    ) {
        self.id = id
        self.owningContainer = containerID
        self.state = Mutex<State>(.init(spec: spec, pid: -1, stdio: StdioHandles()))
        self.ioSetup = io
        self.portAllocator = portAllocator
        self.stdioTimeout = stdioTimeoutSeconds
        self.agent = agent
        self.ociRuntimePath = ociRuntimePath
        self.vm = vm
        self.logger = logger
        self.onDelete = onDelete
    }
}

extension LinuxProcess {
    /// Seconds to wait for the guest to dial back on each stdio vsock port.
    /// The guest only connects once `createProcess` has reached it, so this
    /// window has to cover a loaded guest getting from that RPC to its
    /// `connect(2)` — on a busy host running many VMs that is far more than
    /// the few hundred milliseconds it takes when idle.
    ///
    /// Env: `CONTAINERIZATION_STDIO_TIMEOUT` (seconds, default 30). Values
    /// that aren't a positive integer are ignored.
    ///
    /// The asymmetry is what sets the default high: too long only delays
    /// reporting a guest that was never coming back, while too short
    /// actively corrupts the failure. Expiring tears down the host
    /// listeners, so the guest's own connect is then answered with a reset
    /// and the error surfaced to the caller names a vsock connection
    /// problem instead of a slow guest.
    static let stdioDialBackTimeout: UInt32 = {
        guard let raw = ProcessInfo.processInfo.environment["CONTAINERIZATION_STDIO_TIMEOUT"],
            let seconds = UInt32(raw),
            seconds > 0
        else {
            return 30
        }
        return seconds
    }()

    /// What each sibling task in `start()` reports back.
    private enum StartStep: Sendable {
        case stdio([FileHandle?])
        case processCreated
    }

    func setupIO(listeners: [VsockListener?]) async throws -> [FileHandle?] {
        let timeout = self.stdioTimeout
        let names = ["stdin", "stdout", "stderr"]
        let handles = try await withThrowingTaskGroup(of: (Int, FileHandle?).self) { group in
            var results = [FileHandle?](repeating: nil, count: 3)

            for (index, listener) in listeners.enumerated() {
                guard let listener else { continue }
                let name = names[index]

                group.addTask {
                    let first: FileHandle?
                    // Timed per stream rather than around the whole group so
                    // the error can name the stream the guest never dialed.
                    do {
                        first = try await Timeout.run(seconds: timeout) {
                            await listener.first(where: { _ in true })
                        }
                    } catch {
                        try? listener.finish()
                        // A cancelled sibling — or a cancelled caller — lands
                        // here too. That error isn't ours to relabel, and the
                        // group reports whichever failure came first anyway.
                        if Task.isCancelled {
                            throw error
                        }
                        throw ContainerizationError(
                            .timeout,
                            message: "guest did not dial back for \(name) (vsock port \(listener.port)) "
                                + "within \(timeout)s",
                            cause: error
                        )
                    }
                    try listener.finish()
                    return (index, first)
                }
            }

            for try await (index, fileHandle) in group {
                results[index] = fileHandle
            }
            return results
        }

        // Note: stdin relay is started separately via startStdinRelay() after
        // the process has started, to avoid a deadlock where closeStdin is
        // called before the process is consuming from the pipe.

        var configuredStreams = 0
        let (stream, cc) = AsyncStream<Void>.makeStream()
        if let stdout = self.ioSetup.stdout {
            configuredStreams += 1
            handles[1]?.readabilityHandler = { handle in
                do {
                    let data = handle.availableData
                    if data.isEmpty {
                        // This block is called when the producer (the guest) closes
                        // the fd it is writing into.
                        handles[1]?.readabilityHandler = nil
                        cc.yield()
                        return
                    }
                    try stdout.writer.write(data)
                } catch {
                    self.logger?.error("failed to write to stdout: \(error)")
                }
            }
        }

        if let stderr = self.ioSetup.stderr {
            configuredStreams += 1
            handles[2]?.readabilityHandler = { handle in
                do {
                    let data = handle.availableData
                    if data.isEmpty {
                        handles[2]?.readabilityHandler = nil
                        cc.yield()
                        return
                    }
                    try stderr.writer.write(data)
                } catch {
                    self.logger?.error("failed to write to stderr: \(error)")
                }
            }
        }
        if configuredStreams > 0 {
            self.state.withLock {
                $0.ioTracker = .init(stream: stream, cont: cc, configuredStreams: configuredStreams)
            }
        }

        return handles
    }

    func startStdinRelay(handle: FileHandle) {
        guard let stdin = self.ioSetup.stdin else { return }

        self.state.withLock {
            $0.stdinRelay = Task {
                for await data in stdin.reader.stream() {
                    do {
                        try handle.write(contentsOf: data)
                    } catch {
                        self.logger?.error("failed to write to stdin: \(error)")
                        break
                    }
                }

                do {
                    self.logger?.debug("stdin relay finished, closing")

                    // There's two ways we can wind up here:
                    //
                    // 1. The stream finished on its own (e.g. we wrote all the
                    // data) and we will close the underlying stdin in the guest below.
                    //
                    // 2. The client explicitly called closeStdin() themselves
                    // which will cancel this relay task AFTER actually closing
                    // the fds. If the client did that, then this task will be
                    // cancelled, and the fds are already gone so there's nothing
                    // for us to do.
                    if Task.isCancelled {
                        return
                    }

                    try await self._closeStdin()
                } catch {
                    self.logger?.error("failed to close stdin: \(error)")
                }
            }
        }
    }

    /// Start the process.
    public func start() async throws {
        var pending = [VsockListener?](repeating: nil, count: 3)
        do {
            let spec = self.state.withLock { $0.spec }
            if let stdin = self.ioSetup.stdin {
                pending[0] = try self.vm.listen(stdin.port)
            }
            if let stdout = self.ioSetup.stdout {
                pending[1] = try self.vm.listen(stdout.port)
            }
            if let stderr = self.ioSetup.stderr {
                if spec.process!.terminal {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "stderr should not be configured with terminal=true"
                    )
                }
                pending[2] = try self.vm.listen(stderr.port)
            }
            let listeners = pending

            // setupIO and createProcess must run concurrently: the guest only
            // dials back for stdio once createProcess has reached it. Run them
            // as siblings so whichever fails *first* is the error we report.
            // That ordering is the point. A stdio dial-back timeout tears down
            // the host listeners, after which the guest's own connect is
            // answered with a reset — so if createProcess's error won the race
            // the caller was told "connection reset by peer" for a port that
            // the host itself had stopped listening on moments earlier, which
            // sends every investigation to the wrong layer.
            let result = try await withThrowingTaskGroup(of: StartStep.self, returning: [FileHandle?].self) { group in
                group.addTask {
                    let handles = try await self.setupIO(listeners: listeners)
                    return .stdio(handles)
                }

                group.addTask {
                    try await self.agent.createProcess(
                        id: self.id,
                        containerID: self.owningContainer,
                        stdinPort: self.ioSetup.stdin?.port,
                        stdoutPort: self.ioSetup.stdout?.port,
                        stderrPort: self.ioSetup.stderr?.port,
                        ociRuntimePath: self.ociRuntimePath,
                        configuration: spec,
                        options: nil
                    )
                    return .processCreated
                }

                var handles = [FileHandle?](repeating: nil, count: 3)
                for try await step in group {
                    if case .stdio(let stdio) = step {
                        handles = stdio
                    }
                }
                return handles
            }

            let pid = try await self.agent.startProcess(
                id: self.id,
                containerID: self.owningContainer
            )

            // Start stdin relay after process launch to avoid filling the pipe
            // buffer before the process is even running.
            if let stdinHandle = result[0] {
                self.startStdinRelay(handle: stdinHandle)
            }

            self.state.withLock {
                $0.stdio = StdioHandles(
                    stdin: result[0],
                    stdout: result[1],
                    stderr: result[2]
                )
                $0.pid = pid
            }
        } catch {
            // Release any listener this failure path left open — e.g. a later
            // vm.listen(_:) throwing after earlier ports were already claimed.
            // finish() is idempotent, so streams setupIO already finished are
            // unaffected.
            for listener in pending {
                try? listener?.finish()
            }
            if let err = error as? ContainerizationError {
                throw err
            }
            throw ContainerizationError(
                .internalError,
                message: "failed to start process",
                cause: error,
            )
        }
    }

    /// Kill the process with the specified signal.
    public func kill(_ signal: Signal) async throws {
        do {
            try await agent.signalProcess(
                id: self.id,
                containerID: self.owningContainer,
                signal: signal.rawValue
            )
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to kill process",
                cause: error
            )
        }
    }

    /// Resize the processes pty (if requested).
    public func resize(to: Terminal.Size) async throws {
        do {
            try await agent.resizeProcess(
                id: self.id,
                containerID: self.owningContainer,
                columns: UInt32(to.width),
                rows: UInt32(to.height)
            )
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to resize process",
                cause: error
            )
        }
    }

    public func closeStdin() async throws {
        do {
            try await self._closeStdin()
            self.state.withLock {
                $0.stdinRelay?.cancel()
            }
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to close stdin",
                cause: error,
            )
        }
    }

    func _closeStdin() async throws {
        try await self.agent.closeProcessStdin(
            id: self.id,
            containerID: self.owningContainer
        )
    }

    /// Wait on the process to exit with an optional timeout. Returns the exit code of the process.
    @discardableResult
    public func wait(timeoutInSeconds: Int64? = nil) async throws -> ExitStatus {
        do {
            let exitStatus = try await self.agent.waitProcess(
                id: self.id,
                containerID: self.owningContainer,
                timeoutInSeconds: timeoutInSeconds
            )
            await self.waitIoComplete()
            return exitStatus
        } catch {
            if error is ContainerizationError {
                throw error
            }
            throw ContainerizationError(
                .internalError,
                message: "failed to wait on process",
                cause: error
            )
        }
    }

    /// Wait until the standard output and standard error streams for the process have concluded.
    private func waitIoComplete() async {
        let ioTracker = self.state.withLock { $0.ioTracker }
        guard let ioTracker else {
            return
        }
        do {
            try await Timeout.run(seconds: 3) {
                var counter = ioTracker.configuredStreams
                for await _ in ioTracker.stream {
                    counter -= 1
                    if counter == 0 {
                        ioTracker.cont.finish()
                        break
                    }
                }
            }
        } catch {
            self.logger?.error("timeout waiting for IO to complete for process \(id): \(error)")
        }
        self.state.withLock {
            $0.ioTracker = nil
        }
    }

    /// Cleans up guest state and waits on and closes any host resources (stdio handles).
    public func delete() async throws {
        try await self._delete()
        await self.onDelete?()
    }

    func _delete() async throws {
        let task = self.state.withLock { state in
            if let existingTask = state.deletionTask {
                // Deletion already in progress or finished.
                return existingTask
            }

            let task = Task<Void, Error> {
                try await self.performDeletion()
            }
            state.deletionTask = task
            return task
        }

        try await task.value
    }

    private func performDeletion() async throws {
        // Runs after the paths below have closed the host stdio handles, and
        // only once (performDeletion is guarded by state.deletionTask). Ports
        // deliberately come back at delete rather than at process exit: a
        // straggling guest dial for a finished stream must not be handed to
        // whichever process reuses the number next.
        defer { self.releaseStdioPorts() }

        do {
            try await self.agent.deleteProcess(
                id: self.id,
                containerID: self.owningContainer
            )
        } catch {
            self.state.withLock {
                $0.stdinRelay?.cancel()
                try? $0.stdio.close()
            }
            try? await self.agent.close()
            throw ContainerizationError(
                .internalError,
                message: "failed to delete process",
                cause: error,
            )
        }

        do {
            try self.state.withLock {
                $0.stdinRelay?.cancel()
                try $0.stdio.close()
            }
        } catch {
            try? await self.agent.close()
            throw ContainerizationError(
                .internalError,
                message: "failed to close stdio",
                cause: error,
            )
        }

        do {
            try await self.agent.close()
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to close agent connection",
                cause: error,
            )
        }
    }

    /// Return this process's stdio vsock ports to the allocator. `release` is
    /// idempotent, so overlapping teardown paths don't need to coordinate.
    private func releaseStdioPorts() {
        for port in [self.ioSetup.stdin?.port, self.ioSetup.stdout?.port, self.ioSetup.stderr?.port] {
            guard let port else { continue }
            self.portAllocator.release(port)
        }
    }
}
