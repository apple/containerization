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

import ContainerizationOCI
import ContainerizationOS
import Foundation

/// Log format for runc output
enum LogFormat: String, Sendable {
    case json
    case text
}

/// Configuration and client for interacting with the runc binary
struct Runc: Sendable {
    /// IO configuration for runc operations
    struct IO: Sendable {
        var stdin: FileHandle?
        var stdout: FileHandle?
        var stderr: FileHandle?

        init(
            stdin: FileHandle? = nil,
            stdout: FileHandle? = nil,
            stderr: FileHandle? = nil
        ) {
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
        }

        static let inherit = IO()
    }

    /// Path to the runc binary
    var command: String

    /// Root directory for container state
    var root: String?

    /// Enable debug output
    var debug: Bool

    /// Path to log file
    var log: String?

    /// Format for log output
    var logFormat: LogFormat?

    /// Signal to send when parent process dies
    var pdeathSignal: Int32?

    /// Set process group ID
    var setpgid: Bool

    /// Path to criu binary for checkpoint/restore
    var criu: String?

    /// Use systemd cgroup manager
    var systemdCgroup: Bool

    /// Enable rootless mode
    var rootless: Bool

    /// Additional arguments to pass to runc
    var extraArgs: [String]

    /// Command runner to use instead of direct wait4 (for PID 1 environments with reapers)
    var commandRunner: (any CommandRunner)?

    init(
        command: String = "runc",
        root: String? = nil,
        debug: Bool = false,
        log: String? = nil,
        logFormat: LogFormat? = nil,
        pdeathSignal: Int32? = nil,
        setpgid: Bool = false,
        criu: String? = nil,
        systemdCgroup: Bool = false,
        rootless: Bool = false,
        extraArgs: [String] = [],
        commandRunner: (any CommandRunner)? = nil
    ) {
        self.command = command
        self.root = root
        self.debug = debug
        self.log = log
        self.logFormat = logFormat
        self.pdeathSignal = pdeathSignal
        self.setpgid = setpgid
        self.criu = criu
        self.systemdCgroup = systemdCgroup
        self.rootless = rootless
        self.extraArgs = extraArgs
        self.commandRunner = commandRunner
    }
}

/// Options for creating a container
struct CreateOpts: Sendable {
    /// Path to file to write container PID
    var pidFile: String?

    /// Path to console socket for terminal access
    var consoleSocket: String?

    /// Detach from the container process
    var detach: Bool

    /// Do not use pivot_root to change root
    var noPivot: Bool

    /// Do not create a new session
    var noNewKeyring: Bool

    /// Additional file descriptors to pass to the container
    var extraFiles: [FileHandle]

    /// IO configuration for the runc process
    var io: Runc.IO

    init(
        pidFile: String? = nil,
        consoleSocket: String? = nil,
        detach: Bool = false,
        noPivot: Bool = false,
        noNewKeyring: Bool = false,
        extraFiles: [FileHandle] = [],
        io: Runc.IO = .inherit
    ) {
        self.pidFile = pidFile
        self.consoleSocket = consoleSocket
        self.detach = detach
        self.noPivot = noPivot
        self.noNewKeyring = noNewKeyring
        self.extraFiles = extraFiles
        self.io = io
    }
}

/// Options for executing a process in a container
struct ExecOpts: Sendable {
    /// Path to file to write process PID
    var pidFile: String?

    /// Path to console socket for terminal access
    var consoleSocket: String?

    /// Detach from the process
    var detach: Bool

    /// Path to process.json file
    var processPath: String?

    /// IO configuration for the runc process
    var io: Runc.IO

    init(
        pidFile: String? = nil,
        consoleSocket: String? = nil,
        detach: Bool = false,
        processPath: String? = nil,
        io: Runc.IO = .inherit
    ) {
        self.pidFile = pidFile
        self.consoleSocket = consoleSocket
        self.detach = detach
        self.processPath = processPath
        self.io = io
    }
}

/// Options for deleting a container
struct DeleteOpts: Sendable {
    /// Force deletion of a running container
    var force: Bool

    init(force: Bool = false) {
        self.force = force
    }
}

/// Options for restoring a container from checkpoint
struct RestoreOpts: Sendable {
    /// Path to file to write container PID
    var pidFile: String?

    /// Path to console socket for terminal access
    var consoleSocket: String?

    /// Detach from the container process
    var detach: Bool

    /// Do not use pivot_root to change root
    var noPivot: Bool

    /// Do not create a new session
    var noNewKeyring: Bool

    /// Path to checkpoint image
    var imagePath: String?

    /// Path to parent checkpoint
    var parentPath: String?

    /// Work directory for CRIU
    var workPath: String?

    init(
        pidFile: String? = nil,
        consoleSocket: String? = nil,
        detach: Bool = false,
        noPivot: Bool = false,
        noNewKeyring: Bool = false,
        imagePath: String? = nil,
        parentPath: String? = nil,
        workPath: String? = nil
    ) {
        self.pidFile = pidFile
        self.consoleSocket = consoleSocket
        self.detach = detach
        self.noPivot = noPivot
        self.noNewKeyring = noNewKeyring
        self.imagePath = imagePath
        self.parentPath = parentPath
        self.workPath = workPath
    }
}

/// Container information returned from list operation
struct Container: Sendable, Codable {
    let id: String
    let pid: Int
    let status: String
    let bundle: String
    let rootfs: String
    let created: Date
    let annotations: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id
        case pid
        case status
        case bundle
        case rootfs
        case created
        case annotations
    }
}

extension Runc {
    enum Error: Swift.Error, CustomStringConvertible {
        case invalidJSON(String)
        case commandFailed(Int32, String)
        case invalidPidFile(String)

        var description: String {
            switch self {
            case .invalidJSON(let detail):
                return "invalid JSON: \(detail)"
            case .commandFailed(let status, let output):
                return "command failed with status \(status): \(output)"
            case .invalidPidFile(let path):
                return "invalid or missing PID file: \(path)"
            }
        }
    }
}

// MARK: - Command Building and Execution

extension Runc {
    /// Build base arguments for runc command
    func baseArgs() -> [String] {
        var args: [String] = []

        if let root = root {
            args += ["--root", root]
        }

        if debug {
            args.append("--debug")
        }

        if let log = log {
            args += ["--log", log]
        }

        if let logFormat = logFormat {
            args += ["--log-format", logFormat.rawValue]
        }

        if systemdCgroup {
            args.append("--systemd-cgroup")
        }

        if rootless {
            args.append("--rootless")
        }

        args += extraArgs

        return args
    }

    /// Execute a runc command and return the output
    func execute(
        args: [String],
        stdin: FileHandle? = nil,
        stdout: FileHandle? = nil,
        stderr: FileHandle? = nil,
        extraFiles: [FileHandle] = [],
        directory: String? = nil
    ) async throws -> (status: Int32, output: Data) {
        var cmd = Command(
            command,
            arguments: args,
            directory: directory,
            extraFiles: extraFiles
        )

        // Setup IO
        let outPipe = Pipe()
        cmd.stdin = stdin
        cmd.stdout = stdout ?? outPipe.fileHandleForWriting
        cmd.stderr = stderr ?? outPipe.fileHandleForWriting

        if let pdeathSignal = pdeathSignal {
            cmd.attrs.pdeathSignal = pdeathSignal
        }

        if setpgid {
            cmd.attrs.setPGroup = true
        }

        let exitStatus: Int32

        if let runner = commandRunner {
            let subscription = try runner.start(&cmd)
            exitStatus = try await runner.wait(cmd, subscription: subscription)
        } else {
            try cmd.start()
            exitStatus = try cmd.wait()
        }

        var output = Data()
        if stdout == nil {
            try? outPipe.fileHandleForWriting.close()
            output = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        }

        return (exitStatus, output)
    }

    /// Execute command and parse JSON output
    func executeJSON<T: Decodable>(
        args: [String],
        directory: String? = nil
    ) async throws -> T {
        let (status, output) = try await execute(args: args, directory: directory)

        guard status == 0 else {
            let errorOutput = String(data: output, encoding: .utf8) ?? ""
            throw Error.commandFailed(status, errorOutput)
        }

        do {
            return try JSONDecoder().decode(T.self, from: output)
        } catch {
            let outputStr = String(data: output, encoding: .utf8) ?? ""
            throw Error.invalidJSON("failed to decode: \(error), output: \(outputStr)")
        }
    }

    /// Execute command without capturing output
    func executeVoid(
        args: [String],
        stdin: FileHandle? = nil,
        stdout: FileHandle? = nil,
        stderr: FileHandle? = nil,
        extraFiles: [FileHandle] = [],
        directory: String? = nil
    ) async throws {
        let (status, output) = try await execute(
            args: args,
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            extraFiles: extraFiles,
            directory: directory
        )

        guard status == 0 else {
            let errorOutput = String(data: output, encoding: .utf8) ?? ""
            throw Error.commandFailed(status, errorOutput)
        }
    }

    /// Read PID from a file
    func readPidFile(_ path: String) throws -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let pidString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int(pidString)
        else {
            throw Error.invalidPidFile(path)
        }
        return pid
    }
}

extension Runc {
    /// Create a container
    func create(
        id: String,
        bundle: String,
        opts: CreateOpts = CreateOpts()
    ) async throws -> Int? {
        var args = baseArgs() + ["create"]

        if let pidFile = opts.pidFile {
            args += ["--pid-file", pidFile]
        }

        if let consoleSocket = opts.consoleSocket {
            args += ["--console-socket", consoleSocket]
        }

        if opts.detach {
            args.append("--detach")
        }

        if opts.noPivot {
            args.append("--no-pivot")
        }

        if opts.noNewKeyring {
            args.append("--no-new-keyring")
        }

        args += ["--bundle", bundle, id]

        try await executeVoid(
            args: args,
            stdin: opts.io.stdin,
            stdout: opts.io.stdout,
            stderr: opts.io.stderr,
            extraFiles: opts.extraFiles,
            directory: bundle
        )

        // Read PID if pidFile was specified
        if let pidFile = opts.pidFile {
            return try readPidFile(pidFile)
        }

        return nil
    }

    /// Start a container
    func start(id: String) async throws {
        let args = baseArgs() + ["start", id]
        try await executeVoid(args: args)
    }

    /// Run a container (create + start)
    func run(
        id: String,
        bundle: String,
        opts: CreateOpts = CreateOpts()
    ) async throws -> Int? {
        var args = baseArgs() + ["run"]

        if let pidFile = opts.pidFile {
            args += ["--pid-file", pidFile]
        }

        if let consoleSocket = opts.consoleSocket {
            args += ["--console-socket", consoleSocket]
        }

        if opts.detach {
            args.append("--detach")
        }

        if opts.noPivot {
            args.append("--no-pivot")
        }

        if opts.noNewKeyring {
            args.append("--no-new-keyring")
        }

        args += ["--bundle", bundle, id]

        try await executeVoid(
            args: args,
            stdin: opts.io.stdin,
            stdout: opts.io.stdout,
            stderr: opts.io.stderr,
            extraFiles: opts.extraFiles,
            directory: bundle
        )

        // Read PID if pidFile was specified
        if let pidFile = opts.pidFile {
            return try readPidFile(pidFile)
        }

        return nil
    }

    /// Delete a container
    func delete(id: String, opts: DeleteOpts = DeleteOpts()) async throws {
        var args = baseArgs() + ["delete"]

        if opts.force {
            args.append("--force")
        }

        args.append(id)

        try await executeVoid(args: args)
    }

    /// Send a signal to a container
    func kill(id: String, signal: Int32, all: Bool = false) async throws {
        var args = baseArgs() + ["kill"]

        if all {
            args.append("--all")
        }

        args += [id, String(signal)]

        try await executeVoid(args: args)
    }

    /// Pause a container
    func pause(id: String) async throws {
        let args = baseArgs() + ["pause", id]
        try await executeVoid(args: args)
    }

    /// Resume a paused container
    func resume(id: String) async throws {
        let args = baseArgs() + ["resume", id]
        try await executeVoid(args: args)
    }

    /// Execute a process in a running container
    func exec(
        id: String,
        processSpec: String,
        opts: ExecOpts = ExecOpts()
    ) async throws -> Int? {
        var args = baseArgs() + ["exec"]

        if let pidFile = opts.pidFile {
            args += ["--pid-file", pidFile]
        }

        if let consoleSocket = opts.consoleSocket {
            args += ["--console-socket", consoleSocket]
        }

        if opts.detach {
            args.append("--detach")
        }

        if let processPath = opts.processPath {
            args += ["--process", processPath]
        }

        args += [id, processSpec]

        try await executeVoid(
            args: args,
            stdin: opts.io.stdin,
            stdout: opts.io.stdout,
            stderr: opts.io.stderr
        )

        // Read PID if pidFile was specified
        if let pidFile = opts.pidFile {
            return try readPidFile(pidFile)
        }

        return nil
    }

    /// Update container resources
    func update(id: String, resources: String) async throws {
        let args = baseArgs() + ["update", "--resources", resources, id]
        try await executeVoid(args: args)
    }

    /// Checkpoint a container
    func checkpoint(
        id: String,
        imagePath: String,
        leaveRunning: Bool = false,
        workPath: String? = nil
    ) async throws {
        var args = baseArgs() + ["checkpoint"]

        if leaveRunning {
            args.append("--leave-running")
        }

        if let workPath = workPath {
            args += ["--work-path", workPath]
        }

        args += ["--image-path", imagePath, id]

        try await executeVoid(args: args)
    }

    /// Restore a container from checkpoint
    func restore(
        id: String,
        bundle: String,
        opts: RestoreOpts = RestoreOpts()
    ) async throws -> Int? {
        var args = baseArgs() + ["restore"]

        if let pidFile = opts.pidFile {
            args += ["--pid-file", pidFile]
        }

        if let consoleSocket = opts.consoleSocket {
            args += ["--console-socket", consoleSocket]
        }

        if opts.detach {
            args.append("--detach")
        }

        if opts.noPivot {
            args.append("--no-pivot")
        }

        if opts.noNewKeyring {
            args.append("--no-new-keyring")
        }

        if let imagePath = opts.imagePath {
            args += ["--image-path", imagePath]
        }

        if let parentPath = opts.parentPath {
            args += ["--parent-path", parentPath]
        }

        if let workPath = opts.workPath {
            args += ["--work-path", workPath]
        }

        args += ["--bundle", bundle, id]

        try await executeVoid(args: args, directory: bundle)

        if let pidFile = opts.pidFile {
            return try readPidFile(pidFile)
        }

        return nil
    }
}

// MARK: - List and State Operations

extension Runc {
    /// List all containers
    func list() async throws -> [Container] {
        let args = baseArgs() + ["list", "--format", "json"]
        let containers: [Container] = try await executeJSON(args: args)
        return containers
    }

    /// Get state of a specific container
    func state(id: String) async throws -> ContainerizationOCI.State {
        let args = baseArgs() + ["state", id]
        let state: ContainerizationOCI.State = try await executeJSON(args: args)
        return state
    }

    /// List process IDs in a container
    func ps(id: String) async throws -> [Int] {
        let args = baseArgs() + ["ps", "--format", "json", id]
        let (status, output) = try await execute(args: args)

        guard status == 0 else {
            let errorOutput = String(data: output, encoding: .utf8) ?? ""
            throw Error.commandFailed(status, errorOutput)
        }

        // ps output is just an array of PIDs
        let pids = try JSONDecoder().decode([Int].self, from: output)
        return pids
    }

    /// Get version information
    func version() async throws -> String {
        let args = [command, "--version"]
        let (status, output) = try await execute(args: args)

        guard status == 0 else {
            let errorOutput = String(data: output, encoding: .utf8) ?? ""
            throw Error.commandFailed(status, errorOutput)
        }

        return String(data: output, encoding: .utf8) ?? ""
    }
}

// MARK: - Events

extension Runc {
    /// Event from container runtime
    struct Event: Codable, Sendable {
        let type: String
        let id: String
        let stats: EventStats?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case stats
        }
    }

    /// Statistics in an event
    struct EventStats: Codable, Sendable {
        let cpu: CPUStats?
        let memory: MemoryStats?
        let pids: PIDStats?

        enum CodingKeys: String, CodingKey {
            case cpu
            case memory
            case pids
        }
    }

    struct CPUStats: Codable, Sendable {
        let usage: CPUUsage?
        let throttling: ThrottlingData?

        struct CPUUsage: Codable, Sendable {
            let total: UInt64?
            let percpu: [UInt64]?
        }

        struct ThrottlingData: Codable, Sendable {
            let periods: UInt64?
            let throttledPeriods: UInt64?
            let throttledTime: UInt64?
        }
    }

    struct MemoryStats: Codable, Sendable {
        let usage: MemoryUsage?
        let limit: UInt64?

        struct MemoryUsage: Codable, Sendable {
            let usage: UInt64?
            let max: UInt64?
        }
    }

    struct PIDStats: Codable, Sendable {
        let current: UInt64?
        let limit: UInt64?
    }
}
