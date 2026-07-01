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
import Foundation
import Logging
import NIOCore

/// VirtualMachineManager backed by `cloud-hypervisor` + KVM on Linux.
///
/// One subprocess per VM. The manager itself is just a factory: kernel,
/// initial filesystem, host binary paths, and a runtime root (under which
/// each instance gets its own working directory).
public struct CHVirtualMachineManager: VirtualMachineManager {
    private let kernel: Kernel
    private let initialFilesystem: Mount
    private let chBinary: URL
    private let virtiofsdBinaryOverride: URL?
    private let runtimeRoot: URL
    private let group: (any EventLoopGroup)?
    private let logger: Logger?

    /// - Parameters:
    ///   - kernel: The Linux kernel image used for every VM this manager creates.
    ///   - initialFilesystem: The rootfs `Mount` (typically the `init.ext4`
    ///     blob produced by `make init`).
    ///   - chBinary: Path to the `cloud-hypervisor` binary; if nil, looked
    ///     up on `PATH`. Validated at init time.
    ///   - virtiofsdBinary: Path to `virtiofsd`; if nil, looked up on `PATH`
    ///     lazily — only when a virtiofs share is actually used. A VM that
    ///     boots with only block-device mounts can run without virtiofsd
    ///     installed at all.
    ///   - runtimeRoot: Directory under which per-VM working directories are
    ///     created. Defaults to `/run/containerization/ch`. The directory is
    ///     created with mode `0o700` so per-VM UDS sockets (api.sock,
    ///     vsock.sock, vfs-*.sock) inside aren't reachable by other local
    ///     users. `/run` is tmpfs on every modern Linux distro, so contents
    ///     don't survive reboot — which is the right lifecycle for VM
    ///     runtime state.
    ///   - group: Optional shared NIO `EventLoopGroup`; if nil, each VM
    ///     spawns its own.
    public init(
        kernel: Kernel,
        initialFilesystem: Mount,
        chBinary: URL? = nil,
        virtiofsdBinary: URL? = nil,
        runtimeRoot: URL? = nil,
        group: (any EventLoopGroup)? = nil,
        logger: Logger? = nil
    ) throws {
        self.kernel = kernel
        self.initialFilesystem = initialFilesystem
        self.chBinary = try Self.resolveBinary(chBinary, name: "cloud-hypervisor")
        if let virtiofsdBinary {
            // Validate explicit overrides at init time so misconfiguration
            // surfaces early. PATH-lookup deferral only applies when no
            // override is supplied.
            guard FileManager.default.isExecutableFile(atPath: virtiofsdBinary.path) else {
                throw ContainerizationError(
                    .notFound,
                    message: "virtiofsd not executable at \(virtiofsdBinary.path)"
                )
            }
        }
        self.virtiofsdBinaryOverride = virtiofsdBinary
        let runtimeRoot = runtimeRoot ?? URL(fileURLWithPath: "/run/containerization/ch")
        try FileManager.default.createDirectory(
            at: runtimeRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory only sets attributes on directories it creates, so
        // explicitly tighten an existing dir if a previous run left it at a
        // looser mode.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeRoot.path)
        self.runtimeRoot = runtimeRoot
        self.group = group
        self.logger = logger
    }

    public func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        let vmConfig = config.configuration

        var instanceConfig = CHVirtualMachineInstance.Configuration()
        instanceConfig.cpus = vmConfig.cpus
        instanceConfig.memoryInBytes = vmConfig.memoryInBytes
        instanceConfig.interfaces = vmConfig.interfaces
        instanceConfig.mountsByID = vmConfig.mountsByID
        instanceConfig.bootLog = vmConfig.bootLog
        instanceConfig.extensions = vmConfig.extensions
        instanceConfig.kernel = kernel
        instanceConfig.initialFilesystem = initialFilesystem

        return try CHVirtualMachineInstance(
            group: group,
            config: instanceConfig,
            runtimeRoot: runtimeRoot,
            chBinary: chBinary,
            virtiofsdBinary: virtiofsdBinaryOverride,
            logger: logger
        )
    }

    // MARK: - Binary resolution

    /// Resolve a binary path, accepting an explicit override or falling back to
    /// `PATH` lookup. Used both at manager init for `cloud-hypervisor` and
    /// lazily by the CH instance / hotplug provider for `virtiofsd` so a
    /// block-only VM doesn't require virtiofsd to be installed.
    static func resolveBinary(_ override: URL?, name: String) throws -> URL {
        if let override {
            guard FileManager.default.isExecutableFile(atPath: override.path) else {
                throw ContainerizationError(
                    .notFound,
                    message: "\(name) not executable at \(override.path)"
                )
            }
            return override
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw ContainerizationError(
            .notFound,
            message: "could not find \(name) on PATH; pass an explicit URL to CHVirtualMachineManager.init"
        )
    }
}
#endif
