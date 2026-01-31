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
import ContainerizationOCI
import ContainerizationOS

/// A resource limit (rlimit) configuration for a container process.
public struct LinuxRLimit: Sendable, Hashable {
    /// The kind of resource limit.
    public var kind: Kind
    /// The hard limit value.
    public var hard: UInt64
    /// The soft limit value.
    public var soft: UInt64

    /// Creates a new resource limit.
    ///
    /// - Parameters:
    ///   - kind: The kind of resource limit.
    ///   - hard: The hard limit value.
    ///   - soft: The soft limit value.
    public init(kind: Kind, hard: UInt64, soft: UInt64) {
        self.kind = kind
        self.hard = hard
        self.soft = soft
    }

    /// Creates a new resource limit with the same value for both hard and soft limits.
    ///
    /// - Parameters:
    ///   - kind: The kind of resource limit.
    ///   - limit: The limit value for both hard and soft limits.
    public init(kind: Kind, limit: UInt64) {
        self.kind = kind
        self.hard = limit
        self.soft = limit
    }

    /// Convert to OCI POSIXRlimit format for transport.
    public func toOCI() -> POSIXRlimit {
        POSIXRlimit(type: self.kind.description, hard: self.hard, soft: self.soft)
    }
}

extension LinuxRLimit {
    /// The kind of resource limit.
    public struct Kind: Sendable, Hashable {
        private enum Value: Hashable, Sendable, CaseIterable {
            case addressSpace
            case coreFileSize
            case cpuTime
            case dataSize
            case fileSize
            case locks
            case lockedMemory
            case messageQueue
            case nice
            case openFiles
            case numberOfProcesses
            case residentSetSize
            case realtimePriority
            case realtimeTimeout
            case signalsPending
            case stackSize
        }

        private var value: Value
        private init(_ value: Value) {
            self.value = value
        }

        /// Maximum size of the process's virtual memory (address space) in bytes.
        public static var addressSpace: Self {
            Self(.addressSpace)
        }

        /// Maximum size of a core file in bytes.
        public static var coreFileSize: Self {
            Self(.coreFileSize)
        }

        /// Maximum amount of CPU time the process can consume in seconds.
        public static var cpuTime: Self {
            Self(.cpuTime)
        }

        /// Maximum size of the process's data segment in bytes.
        public static var dataSize: Self {
            Self(.dataSize)
        }

        /// Maximum size of files the process may create in bytes.
        public static var fileSize: Self {
            Self(.fileSize)
        }

        /// Maximum number of file locks.
        public static var locks: Self {
            Self(.locks)
        }

        /// Maximum number of bytes of memory that may be locked into RAM.
        public static var lockedMemory: Self {
            Self(.lockedMemory)
        }

        /// Maximum number of bytes that can be allocated for POSIX message queues.
        public static var messageQueue: Self {
            Self(.messageQueue)
        }

        /// Maximum nice value that can be set.
        public static var nice: Self {
            Self(.nice)
        }

        /// Maximum number of open file descriptors.
        public static var openFiles: Self {
            Self(.openFiles)
        }

        /// Maximum number of processes that can be created by the user.
        public static var numberOfProcesses: Self {
            Self(.numberOfProcesses)
        }

        /// Maximum size of the process's resident set (physical memory) in bytes.
        public static var residentSetSize: Self {
            Self(.residentSetSize)
        }

        /// Maximum real-time scheduling priority.
        public static var realtimePriority: Self {
            Self(.realtimePriority)
        }

        /// Maximum amount of CPU time for real-time scheduling in microseconds.
        public static var realtimeTimeout: Self {
            Self(.realtimeTimeout)
        }

        /// Maximum number of signals that may be queued.
        public static var signalsPending: Self {
            Self(.signalsPending)
        }

        /// Maximum size of the process stack in bytes.
        public static var stackSize: Self {
            Self(.stackSize)
        }

        /// Creates a Kind from its OCI string representation.
        ///
        /// - Parameter string: The OCI string representation (e.g., "RLIMIT_NOFILE").
        /// - Throws: `ContainerizationError` with code `.invalidArgument` if the string doesn't match a known rlimit kind.
        public init(_ string: String) throws {
            switch string {
            case "RLIMIT_AS":
                self = .addressSpace
            case "RLIMIT_CORE":
                self = .coreFileSize
            case "RLIMIT_CPU":
                self = .cpuTime
            case "RLIMIT_DATA":
                self = .dataSize
            case "RLIMIT_FSIZE":
                self = .fileSize
            case "RLIMIT_LOCKS":
                self = .locks
            case "RLIMIT_MEMLOCK":
                self = .lockedMemory
            case "RLIMIT_MSGQUEUE":
                self = .messageQueue
            case "RLIMIT_NICE":
                self = .nice
            case "RLIMIT_NOFILE":
                self = .openFiles
            case "RLIMIT_NPROC":
                self = .numberOfProcesses
            case "RLIMIT_RSS":
                self = .residentSetSize
            case "RLIMIT_RTPRIO":
                self = .realtimePriority
            case "RLIMIT_RTTIME":
                self = .realtimeTimeout
            case "RLIMIT_SIGPENDING":
                self = .signalsPending
            case "RLIMIT_STACK":
                self = .stackSize
            default:
                throw ContainerizationError(.invalidArgument, message: "invalid rlimit kind: '\(string)'")
            }
        }
    }
}

extension LinuxRLimit.Kind: CustomStringConvertible {
    /// The OCI string representation of the resource limit kind.
    public var description: String {
        switch self.value {
        case .addressSpace:
            "RLIMIT_AS"
        case .coreFileSize:
            "RLIMIT_CORE"
        case .cpuTime:
            "RLIMIT_CPU"
        case .dataSize:
            "RLIMIT_DATA"
        case .fileSize:
            "RLIMIT_FSIZE"
        case .locks:
            "RLIMIT_LOCKS"
        case .lockedMemory:
            "RLIMIT_MEMLOCK"
        case .messageQueue:
            "RLIMIT_MSGQUEUE"
        case .nice:
            "RLIMIT_NICE"
        case .openFiles:
            "RLIMIT_NOFILE"
        case .numberOfProcesses:
            "RLIMIT_NPROC"
        case .residentSetSize:
            "RLIMIT_RSS"
        case .realtimePriority:
            "RLIMIT_RTPRIO"
        case .realtimeTimeout:
            "RLIMIT_RTTIME"
        case .signalsPending:
            "RLIMIT_SIGPENDING"
        case .stackSize:
            "RLIMIT_STACK"
        }
    }
}

/// User-friendly Linux capabilities configuration
public struct LinuxCapabilities: Sendable {
    /// Capabilities that define the maximum set of capabilities a process can have
    public var bounding: [CapabilityName] = []
    /// Capabilities that are actually in effect for the current process
    public var effective: [CapabilityName] = []
    /// Capabilities that can be inherited by child processes
    public var inheritable: [CapabilityName] = []
    /// Capabilities that are currently permitted for the process
    public var permitted: [CapabilityName] = []
    /// Capabilities that are preserved across execve() calls
    public var ambient: [CapabilityName] = []

    /// Grant all capabilities
    public static let allCapabilities = LinuxCapabilities(
        bounding: CapabilityName.allCases,
        effective: CapabilityName.allCases,
        inheritable: CapabilityName.allCases,
        permitted: CapabilityName.allCases,
        ambient: CapabilityName.allCases
    )

    /// Default configuration
    public static let defaultOCICapabilities = LinuxCapabilities(
        bounding: [
            .chown,
            .dacOverride,
            .fsetid,
            .fowner,
            .mknod,
            .netRaw,
            .setgid,
            .setuid,
            .setfcap,
            .setpcap,
            .netBindService,
            .sysChroot,
            .kill,
            .auditWrite,
        ],
        effective: [
            .chown,
            .dacOverride,
            .fsetid,
            .fowner,
            .mknod,
            .netRaw,
            .setgid,
            .setuid,
            .setfcap,
            .setpcap,
            .netBindService,
            .sysChroot,
            .kill,
            .auditWrite,
        ],
        permitted: [
            .chown,
            .dacOverride,
            .fsetid,
            .fowner,
            .mknod,
            .netRaw,
            .setgid,
            .setuid,
            .setfcap,
            .setpcap,
            .netBindService,
            .sysChroot,
            .kill,
            .auditWrite,
        ],
    )

    public init(
        bounding: [CapabilityName] = [],
        effective: [CapabilityName] = [],
        inheritable: [CapabilityName] = [],
        permitted: [CapabilityName] = [],
        ambient: [CapabilityName] = []
    ) {
        self.bounding = bounding
        self.effective = effective
        self.inheritable = inheritable
        self.permitted = permitted
        self.ambient = ambient
    }

    /// Convenience initializer that sets the same capabilities to effective, permitted, and bounding sets
    /// This matches the typical pattern used by containerd/runc
    public init(capabilities: [CapabilityName]) {
        self.bounding = capabilities
        self.effective = capabilities
        self.inheritable = []
        self.permitted = capabilities
        self.ambient = []
    }

    /// Convert to OCI format for transport
    public func toOCI() -> ContainerizationOCI.LinuxCapabilities {
        ContainerizationOCI.LinuxCapabilities(
            bounding: bounding.isEmpty ? nil : bounding.map { $0.description },
            effective: effective.isEmpty ? nil : effective.map { $0.description },
            inheritable: inheritable.isEmpty ? nil : inheritable.map { $0.description },
            permitted: permitted.isEmpty ? nil : permitted.map { $0.description },
            ambient: ambient.isEmpty ? nil : ambient.map { $0.description }
        )
    }
}

public struct LinuxProcessConfiguration: Sendable {
    /// The default PATH value for a process.
    public static let defaultPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    /// The arguments for the container process.
    public var arguments: [String] = []
    /// The environment variables for the container process.
    public var environmentVariables: [String] = ["PATH=\(Self.defaultPath)"]
    /// The working directory for the container process.
    public var workingDirectory: String = "/"
    /// The user the container process will run as.
    public var user: ContainerizationOCI.User = .init()
    /// The rlimits for the container process.
    public var rlimits: [LinuxRLimit] = []
    /// The Linux capabilities for the container process.
    public var capabilities: LinuxCapabilities = .allCapabilities
    /// Whether to allocate a pseudo terminal for the process. If you'd like interactive
    /// behavior and are planning to use a terminal for stdin/out/err on the client side,
    /// this should likely be set to true.
    public var terminal: Bool = false
    /// The stdin for the process.
    public var stdin: ReaderStream?
    /// The stdout for the process.
    public var stdout: Writer?
    /// The stderr for the process.
    public var stderr: Writer?

    public init() {}

    public init(
        arguments: [String],
        environmentVariables: [String] = ["PATH=\(Self.defaultPath)"],
        workingDirectory: String = "/",
        user: ContainerizationOCI.User = .init(),
        rlimits: [LinuxRLimit] = [],
        capabilities: LinuxCapabilities = .allCapabilities,
        terminal: Bool = false,
        stdin: ReaderStream? = nil,
        stdout: Writer? = nil,
        stderr: Writer? = nil
    ) {
        self.arguments = arguments
        self.environmentVariables = environmentVariables
        self.workingDirectory = workingDirectory
        self.user = user
        self.rlimits = rlimits
        self.capabilities = capabilities
        self.terminal = terminal
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    public init(from config: ImageConfig) {
        self.workingDirectory = config.workingDir ?? "/"
        self.environmentVariables = config.env ?? []
        self.arguments = (config.entrypoint ?? []) + (config.cmd ?? [])
        self.user = {
            if let rawString = config.user {
                return User(username: rawString)
            }
            return User()
        }()
    }

    /// Sets up IO to be handled by the passed in Terminal, and edits the
    /// process configuration to set the necessary state for using a pty.
    mutating public func setTerminalIO(terminal: Terminal) {
        self.environmentVariables.append("TERM=xterm")
        self.terminal = true
        self.stdin = terminal
        self.stdout = terminal
    }

    func toOCI() -> ContainerizationOCI.Process {
        ContainerizationOCI.Process(
            args: self.arguments,
            cwd: self.workingDirectory,
            env: self.environmentVariables,
            capabilities: self.capabilities.toOCI(),
            user: self.user,
            rlimits: self.rlimits.map { $0.toOCI() },
            terminal: self.terminal
        )
    }
}
