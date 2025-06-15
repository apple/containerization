//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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
    /// `IOHandler` informs the process about what should be done
    /// for the stdio streams.
    public struct IOHandler: Sendable {
        public var stdin: ReaderStream?
        public var stdout: Writer?
        public var stderr: Writer?

        public init(stdin: ReaderStream? = nil, stdout: Writer? = nil, stderr: Writer? = nil) {
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
        }

        public static func nullIO() -> IOHandler {
            .init()
        }
    }

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
        var ioCompletionTask: Task<Void, Never>?
    }

    /// The process ID for the container process. This will be -1
    /// if the process has not been started.
    public var pid: Int32 {
        state.withLock { $0.pid }
    }

    /// Arguments passed to the Process.
    public var arguments: [String] {
        get {
            state.withLock { $0.spec.process!.args }
        }
        set {
            state.withLock { $0.spec.process!.args = newValue }
        }
    }

    /// Environment variables for the Process.
    public var environment: [String] {
        get { state.withLock { $0.spec.process!.env } }
        set { state.withLock { $0.spec.process!.env = newValue } }
    }

    /// The current working directory (cwd) for the Process.
    public var workingDirectory: String {
        get { state.withLock { $0.spec.process!.cwd } }
        set { state.withLock { $0.spec.process!.cwd = newValue } }
    }

    /// A boolean value indicating if a Terminal or PTY device should
    /// be attached to the Process's Standard I/O.
    public var terminal: Bool {
        get { state.withLock { $0.spec.process!.terminal } }
        set { state.withLock { $0.spec.process!.terminal = newValue } }
    }

    /// The User a Process should execute under.
    public var user: ContainerizationOCI.User {
        get { state.withLock { $0.spec.process!.user } }
        set { state.withLock { $0.spec.process!.user = newValue } }
    }

    /// Rlimits for the Process.
    public var rlimits: [POSIXRlimit] {
        get { state.withLock { $0.spec.process!.rlimits } }
        set { state.withLock { $0.spec.process!.rlimits = newValue } }
    }

    private let state: Mutex<State>
    private let ioSetup: Stdio
    private let agent: any VirtualMachineAgent
    private let vm: any VirtualMachineInstance
    private let logger: Logger?

    init(
        _ id: String,
        containerID: String? = nil,
        spec: Spec,
        io: Stdio,
        agent: any VirtualMachineAgent,
        vm: any VirtualMachineInstance,
        logger: Logger?
    ) {
        self.id = id
        self.owningContainer = containerID
        self.state = Mutex<State>(.init(spec: spec, pid: -1, stdio: StdioHandles()))
        self.ioSetup = io
        self.agent = agent
        self.vm = vm
        self.logger = logger
    }
}

extension LinuxProcess {
    func setupIO(streams: [VsockConnectionStream?]) async throws -> (handles: [FileHandle?], ioGroup: DispatchGroup) {
        let handles = try await Timeout.run(seconds: 3) {
            await withTaskGroup(of: (Int, FileHandle?).self) { group in
                var results = [FileHandle?](repeating: nil, count: 3)
                for (index, stream) in streams.enumerated() {
                    guard let stream = stream else { continue }
                    group.addTask {
                        let first = await stream.connections.first(where: { _ in true })
                        return (index, first)
                    }
                }
                for await (index, fileHandle) in group {
                    results[index] = fileHandle
                }
                return results
            }
        }

        let ioGroup = DispatchGroup()
        var stdinRelayTask: Task<(), Never>?

        defer {
            if Task.isCancelled {
                for handle in handles {
                    handle?.readabilityHandler = nil
                }
                stdinRelayTask?.cancel()
            }
        }

        if let stdin = self.ioSetup.stdin {
            if let handle = handles[0] {
                ioGroup.enter()
                let group = ioGroup
                $0.stdinRelay = Task {
                    defer { group.leave() }
                    for await data in stdin.reader.stream() {
                        do {
                            try handle.write(contentsOf: data)
                        } catch {
                            self.logger?.error("failed to write to stdin: \(error)")
                            return
                        }
                    }
                }
            }
        }

        if let stdout = self.ioSetup.stdout {
            ioGroup.enter()
            let group = ioGroup
            let didLeave = AtomicBoolean(false)
            handles[1]?.readabilityHandler = { handle in
                guard !didLeave.load() else { return }
                do {
                    let data = handle.availableData
                    if data.isEmpty {
                        if didLeave.compareAndSwap(expected: false, desired: true) {
                            handles[1]?.readabilityHandler = nil
                            group.leave()
                        }
                        return
                    }
                    try stdout.writer.write(data)
                } catch {
                    self.logger?.error("failed to write to stdout: \(error)")
                    if didLeave.compareAndSwap(expected: false, desired: true) {
                        handles[1]?.readabilityHandler = nil
                        group.leave()
                    }
                }
            }
        }

        if let stderr = self.ioSetup.stderr {
            ioGroup.enter()
            let group = ioGroup
            let didLeave = AtomicBoolean(false)
            handles[2]?.readabilityHandler = { handle in
                guard !didLeave.load() else { return }
                do {
                    let data = handle.availableData
                    if data.isEmpty {
                        if didLeave.compareAndSwap(expected: false, desired: true) {
                            handles[2]?.readabilityHandler = nil
                            group.leave()
                        }
                        return
                    }
                    try stderr.writer.write(data)
                } catch {
                    self.logger?.error("failed to write to stderr: \(error)")
                    if didLeave.compareAndSwap(expected: false, desired: true) {
                        handles[2]?.readabilityHandler = nil
                        group.leave()
                    }
                }
            }
        }

        return (handles, ioGroup)
    }

    /// Start the process.
    public func start() async throws {
        let spec = self.state.withLock { $0.spec }

        var streams = [VsockConnectionStream?](repeating: nil, count: 3)
        if let stdin = self.ioSetup.stdin {
            streams[0] = try self.vm.listen(stdin.port)
        }
        if let stdout = self.ioSetup.stdout {
            streams[1] = try self.vm.listen(stdout.port)
        }
        if let stderr = self.ioSetup.stderr {
            if spec.process!.terminal {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "stderr should not be configured with terminal=true"
                )
            }
            streams[2] = try self.vm.listen(stderr.port)
        }

        let t = Task {
            try await self.setupIO(streams: streams)
        }

        try await agent.createProcess(
            id: self.id,
            containerID: self.owningContainer,
            stdinPort: self.ioSetup.stdin?.port,
            stdoutPort: self.ioSetup.stdout?.port,
            stderrPort: self.ioSetup.stderr?.port,
            configuration: spec,
            options: nil
        )

        let (handles, ioGroup) = try await t.value
        let pid = try await self.agent.startProcess(
            id: self.id,
            containerID: self.owningContainer
        )

        let ioCompletionTask = Task {
            ioGroup.wait()
        }

        self.state.withLock {
            $0.stdio = StdioHandles(
                stdin: handles[0],
                stdout: handles[1],
                stderr: handles[2]
            )
            $0.pid = pid
            $0.ioCompletionTask = ioCompletionTask
        }
    }

    /// Kill the process with the specified signal.
    public func kill(_ signal: Int32) async throws {
        try await agent.signalProcess(
            id: self.id,
            containerID: self.owningContainer,
            signal: signal
        )
    }

    /// Resize the processes pty (if requested).
    public func resize(to: Terminal.Size) async throws {
        try await agent.resizeProcess(
            id: self.id,
            containerID: self.owningContainer,
            columns: UInt32(to.width),
            rows: UInt32(to.height)
        )
    }

    /// Wait on the process to exit with an optional timeout. Returns the exit code of the process.
    @discardableResult
    public func wait(timeoutInSeconds: Int64? = nil) async throws -> Int32 {
        do {
            return try await self.agent.waitProcess(
                id: self.id,
                containerID: self.owningContainer,
                timeoutInSeconds: timeoutInSeconds
            )
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

    /// Cleans up guest state and waits on and closes any host resources (stdio handles).
    public func delete() async throws {
        try await self.agent.deleteProcess(
            id: self.id,
            containerID: self.owningContainer
        )

        if let ioCompletionTask = self.state.withLock({ $0.ioCompletionTask }) {
            _ = try? await Timeout.run(seconds: 3) {
                await ioCompletionTask.value
            }
        }

        // Now free up stdio handles.
        try self.state.withLock {
            $0.stdinRelay?.cancel()
            try $0.stdio.close()
        }

        // Finally, close our agent conn.
        try await self.agent.close()
    }
}