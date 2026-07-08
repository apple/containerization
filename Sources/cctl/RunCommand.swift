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

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation

#if os(macOS)
extension Application {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a container"
        )

        @Option(name: [.customLong("image"), .customShort("i")], help: "Image reference to base the container on")
        var imageReference: String = "docker.io/library/alpine:3.16"

        @Option(name: .long, help: "id for the container")
        var id: String = "cctl"

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "Number of CPUs to allocate to the container")
        var cpus: Int = 2

        @Option(name: [.customLong("memory"), .customShort("m")], help: "Amount of memory in megabytes")
        var memory: UInt64 = 1024

        @Option(name: .customLong("fs-size"), help: "The size to create the block filesystem as")
        var fsSizeInMB: UInt64 = 2048

        @Flag(name: .customLong("rosetta"), help: "Enable rosetta x64 emulation")
        var rosetta = false

        @Option(name: .customLong("mount"), help: "Directory to share into the container (Example: /foo:/bar)")
        var mounts: [String] = []

        @Option(name: .customLong("ns"), help: "Nameserver addresses")
        var nameservers: [String] = []

        @Option(name: .long, help: "Path to OCI runtime to use for spawning the container")
        var ociRuntimePath: String?

        @Flag(name: .long, help: "Make rootfs readonly")
        var readOnly: Bool = false

        @Flag(name: .long, help: "Run with an init process for signal forwarding and zombie reaping")
        var `init`: Bool = false

        @Option(
            name: [.customLong("kernel"), .customShort("k")], help: "Kernel binary path", completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        public var kernel: String

        @Option(name: .long, help: "Current working directory")
        var cwd: String = "/"

        @Argument(parsing: .captureForPassthrough)
        var arguments: [String] = ["/bin/sh"]

        func run() async throws {
            let kernel = Kernel(
                path: URL(fileURLWithPath: kernel),
                platform: .linuxArm
            )

            // Choose network implementation based on macOS version
            let network: Network?
            if #available(macOS 26, *) {
                network = try VmnetNetwork()
            } else {
                network = nil
            }

            var manager = try await ContainerManager(
                kernel: kernel,
                initfsReference: "vminit:latest",
                network: network,
                rosetta: rosetta
            )
            let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])

            let current = try Terminal.current
            try current.setraw()
            defer { current.tryReset() }

            let container = try await manager.create(
                id,
                reference: imageReference,
                rootfsSizeInBytes: fsSizeInMB.mib(),
                readOnly: readOnly,
                networking: true
            ) { config in
                config.cpus = cpus
                config.memoryInBytes = memory.mib()
                config.process.setTerminalIO(terminal: current)
                config.process.arguments = arguments
                config.process.workingDirectory = cwd

                for mount in self.mounts {
                    let paths = mount.split(separator: ":")
                    if paths.count != 2 {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "incorrect mount format detected: \(mount)"
                        )
                    }
                    let host = String(paths[0])
                    let guest = String(paths[1])
                    let czMount = Containerization.Mount.share(
                        source: host,
                        destination: guest
                    )
                    config.mounts.append(czMount)
                }

                var hosts = Hosts.default
                if !nameservers.isEmpty {
                    if #available(macOS 26, *) {
                        config.dns = DNS(nameservers: nameservers)
                    } else {
                        print("Warning: Networking not supported on macOS < 26, ignoring DNS configuration")
                    }
                }

                // Add host entry for the container using just the IP (not CIDR)
                if #available(macOS 26, *), !config.interfaces.isEmpty {
                    let interface = config.interfaces[0]
                    hosts.entries.append(
                        Hosts.Entry(
                            ipAddress: interface.ipv4Address.address.description,
                            hostnames: [id]
                        ))
                }

                config.hosts = hosts
                if let ociRuntimePath {
                    config.ociRuntimePath = ociRuntimePath
                    config.mounts = LinuxContainer.defaultOCIMounts()
                }

                config.useInit = self.`init`
            }

            defer {
                try? manager.delete(id)
            }

            try await container.create()
            try await container.start()

            // Resize the containers pty to the current terminal window.
            try? await container.resize(to: try current.size)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in sigwinchStream.signals {
                        try await container.resize(to: try current.size)
                    }
                }

                try await container.wait()
                group.cancelAll()

                try await container.stop()
            }
        }

        private static let appRoot: URL = {
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            .appendingPathComponent("com.apple.containerization")
        }()
    }
}
#endif

#if os(Linux)
extension Application {
    /// Linux-side `cctl run` — boots a container in a cloud-hypervisor VM.
    ///
    /// Mirrors the macOS `cctl run` UX: `-i / --image` pulls and unpacks the
    /// container image into an ext4 rootfs automatically. The Linux-specific
    /// surface is `--initfs` (the deployment ships an `initfs.ext4` containing
    /// vminitd; macOS resolves the equivalent via the local image store, but
    /// on Linux the boot artifact is a path on disk).
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a container via cloud-hypervisor"
        )

        @Option(name: [.customLong("image"), .customShort("i")], help: "Image reference to base the container on")
        var imageReference: String = "docker.io/library/alpine:3.16"

        @Option(name: .long, help: "id for the container")
        var id: String = "cctl"

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "Number of CPUs to allocate")
        var cpus: Int = 2

        @Option(name: [.customLong("memory"), .customShort("m")], help: "Amount of memory in MiB")
        var memory: UInt64 = 1024

        @Option(name: .customLong("fs-size"), help: "The size to create the container rootfs ext4 as (MiB)")
        var fsSizeInMB: UInt64 = 2048

        @Option(name: .customLong("mount"), help: "Directory to share into the container (Example: /foo:/bar)")
        var mounts: [String] = []

        @Option(name: .long, help: "Path to OCI runtime to use for spawning the container")
        var ociRuntimePath: String?

        @Flag(name: .long, help: "Make rootfs readonly")
        var readOnly: Bool = false

        @Flag(name: .long, help: "Run with an init process for signal forwarding and zombie reaping")
        var `init`: Bool = false

        @Option(
            name: [.customLong("kernel"), .customShort("k")],
            help: "Path to the Linux kernel image",
            completion: .file()
        )
        var kernel: String

        @Option(
            name: .customLong("initfs"),
            help: "Path to the ext4 initfs containing vminitd (boots the VM as PID 1)",
            completion: .file()
        )
        var initfs: String

        @Option(
            name: .customLong("bridge"),
            help: "Bridge interface name to attach the container TAP to"
        )
        var bridge: String = "cz0"

        @Option(
            name: .customLong("subnet"),
            help: "IPv4 subnet for the container network (CIDR)"
        )
        var subnet: String = "192.168.64.0/24"

        @Option(
            name: .customLong("gateway"),
            help: "Host-side IPv4 on the bridge (defaults to subnet.lower+1)"
        )
        var bridgeGateway: String?

        @Option(
            name: .customLong("egress"),
            help: "Egress interface for outbound NAT (default: auto-detect from default route)"
        )
        var egress: String?

        @Flag(name: .customLong("no-network"), help: "Skip all host network setup; container has no interface")
        var noNetwork: Bool = false

        @Flag(
            name: .customLong("enable-nat"),
            help:
                "Program iptables MASQUERADE/FORWARD and enable ip_forward so the container can reach external networks. Off by default — the bridge stays internal-only."
        )
        var enableNAT: Bool = false

        @Option(name: .customLong("ns"), help: "Nameserver addresses (default: read host /etc/resolv.conf)")
        var nameservers: [String] = []

        @Option(
            name: .customLong("ch-binary"),
            help: "Path to cloud-hypervisor binary (defaults to PATH lookup)"
        )
        var chBinary: String?

        @Option(
            name: .customLong("virtiofsd-binary"),
            help: "Path to virtiofsd binary (defaults to PATH lookup)"
        )
        var virtiofsdBinary: String?

        @Option(name: .long, help: "Current working directory")
        var cwd: String = "/"

        @Argument(parsing: .captureForPassthrough)
        var arguments: [String] = ["/bin/sh"]

        func run() async throws {
            #if arch(arm64)
            let kernelPlatform = SystemPlatform.linuxArm
            #elseif arch(x86_64)
            let kernelPlatform = SystemPlatform.linuxAmd
            #else
            #error("unsupported host architecture for `cctl run` (expected arm64 or x86_64)")
            #endif
            let imagePlatform = Platform.current

            let kernelObj = Kernel(
                path: URL(fileURLWithPath: kernel),
                platform: kernelPlatform
            )

            // Wire up the host TTY when there is one. `Terminal.current` walks
            // STDERR/STDOUT/STDIN looking for a tty fd and throws if none of
            // them is one (e.g. all stdio piped). In that case fall through to
            // the non-interactive path so `cctl run /bin/true` still works.
            let hostTerminal = try? Terminal.current
            if let hostTerminal {
                try hostTerminal.setraw()
            }
            defer { hostTerminal?.tryReset() }
            let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])

            // Pull the container image and unpack to a per-container ext4 (same
            // shape as ContainerManager.unpack on macOS: reuse the existing
            // rootfs.ext4 if it's already there, fresh-unpack otherwise).
            let imageStore = Application.imageStore
            let reference = try Reference.parse(imageReference)
            reference.normalize()
            let normalizedRef = reference.description
            if normalizedRef != imageReference {
                print("Reference resolved to \(normalizedRef)")
            }
            let image = try await imageStore.get(reference: normalizedRef, pull: true)

            let containersRoot = Application.appRoot
                .appendingPathComponent("containers")
                .appendingPathComponent(id)
            try FileManager.default.createDirectory(at: containersRoot, withIntermediateDirectories: true)
            let rootfsPath = containersRoot.appendingPathComponent("rootfs.ext4")

            var rootfsMount: Containerization.Mount
            do {
                let unpacker = EXT4Unpacker(blockSizeInBytes: fsSizeInMB.mib())
                rootfsMount = try await unpacker.unpack(image, for: imagePlatform, at: rootfsPath)
            } catch let err as ContainerizationError where err.code == .exists {
                rootfsMount = .block(
                    format: "ext4",
                    source: rootfsPath.absolutePath(),
                    destination: "/",
                    options: []
                )
            }
            if readOnly {
                rootfsMount.options.append("ro")
            }

            let initfsMount = Mount.block(
                format: "ext4",
                source: initfs,
                destination: "/",
                options: ["ro"]
            )

            let manager = try CHVirtualMachineManager(
                kernel: kernelObj,
                initialFilesystem: initfsMount,
                chBinary: chBinary.map { URL(fileURLWithPath: $0) },
                virtiofsdBinary: virtiofsdBinary.map { URL(fileURLWithPath: $0) },
                logger: log
            )

            // Seed process config from the image (entrypoint, env, cwd, user),
            // then layer user-provided overrides on top — same precedence as
            // ContainerManager + macOS Run.
            let imageConfig = try await image.config(for: imagePlatform).config
            var processConfig = LinuxProcessConfiguration()
            if let imageConfig {
                processConfig = .init(from: imageConfig)
            }
            processConfig.arguments = arguments
            processConfig.workingDirectory = cwd
            if let hostTerminal {
                processConfig.setTerminalIO(terminal: hostTerminal)
            }

            var interfaces: [any Interface] = []
            var dnsConfig: DNS? = nil
            var hostsConfig: Hosts? = nil

            if !noNetwork {
                let subnetCIDR = try CIDRv4(subnet)
                let gw = try bridgeGateway.map { try IPv4Address($0) }

                let mgr = try BridgeManager.make(
                    name: bridge,
                    subnet: subnetCIDR,
                    gateway: gw,
                    mtu: 1500,
                    egressInterface: egress,
                    enableNAT: enableNAT,
                    logger: log
                )
                try mgr.create()

                var network = try LinuxBridgedNetwork(
                    subnet: subnetCIDR,
                    gateway: gw,
                    bridge: bridge,
                    mtu: 1500
                )
                if let iface = try network.createInterface(id) {
                    interfaces.append(iface)

                    var h = Hosts.default
                    h.entries.append(
                        .init(
                            ipAddress: iface.ipv4Address.address.description,
                            hostnames: [id]
                        ))
                    hostsConfig = h

                    let resolved =
                        nameservers.isEmpty
                        ? Self.readHostNameservers()
                        : nameservers
                    dnsConfig = DNS(nameservers: resolved)
                }
            }

            let cpusCount = cpus
            let memoryBytes = memory.mib()
            let networkInterfaces = interfaces
            let useInit = self.`init`
            let extraMounts = self.mounts
            let runtimePath = self.ociRuntimePath
            let dns = dnsConfig
            let hosts = hostsConfig

            let container = try LinuxContainer(
                id,
                rootfs: rootfsMount,
                vmm: manager,
                logger: log
            ) { config in
                config.process = processConfig
                config.cpus = cpusCount
                config.memoryInBytes = memoryBytes
                config.interfaces = networkInterfaces
                config.useInit = useInit
                if let dns { config.dns = dns }
                if let hosts { config.hosts = hosts }

                for mount in extraMounts {
                    let paths = mount.split(separator: ":")
                    if paths.count != 2 {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "incorrect mount format detected: \(mount)"
                        )
                    }
                    config.mounts.append(
                        Mount.share(source: String(paths[0]), destination: String(paths[1]))
                    )
                }

                if let runtimePath {
                    config.ociRuntimePath = runtimePath
                    config.mounts = LinuxContainer.defaultOCIMounts()
                }
            }

            try await container.create()
            try await container.start()

            // Sync the guest pty winsize to the host on start, and on every
            // SIGWINCH while running. Only meaningful when we have a tty.
            if let hostTerminal {
                try? await container.resize(to: try hostTerminal.size)
            }

            let exit = try await withThrowingTaskGroup(
                of: Void.self,
                returning: ExitStatus.self
            ) { group in
                if let hostTerminal {
                    group.addTask {
                        for await _ in sigwinchStream.signals {
                            try await container.resize(to: try hostTerminal.size)
                        }
                    }
                }
                let result = try await container.wait()
                group.cancelAll()
                try await container.stop()
                return result
            }

            if exit.exitCode != 0 {
                throw ExitCode(exit.exitCode)
            }
        }

        /// Read `nameserver` lines from `/etc/resolv.conf`. Returns
        /// `["1.1.1.1"]` if the file is missing or has no entries.
        private static func readHostNameservers() -> [String] {
            guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
                return ["1.1.1.1"]
            }
            let servers =
                text
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard parts.count == 2, parts[0] == "nameserver" else { return nil }
                    return String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            return servers.isEmpty ? ["1.1.1.1"] : servers
        }
    }
}
#endif
