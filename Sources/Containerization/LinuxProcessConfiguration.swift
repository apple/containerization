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
    public var rlimits: [POSIXRlimit] = []
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
        rlimits: [POSIXRlimit] = [],
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
            rlimits: self.rlimits,
            terminal: self.terminal
        )
    }
}
