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

import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import Synchronization
import SystemPackage

import struct ContainerizationOS.Terminal

/// `LinuxContainer` is an easy to use type for launching and managing the
/// full lifecycle of a Linux container ran inside of a virtual machine.
public final class LinuxContainer: Container, Sendable {
    public static let maxIDLength = 64

    /// The identifier of the container.
    public let id: String

    /// Rootfs for the container.
    ///
    /// Note: The `destination` field of this mount is ignored as mounting is handled internally.
    public let rootfs: Mount

    /// Optional writable layer for the container. When provided, the rootfs
    /// is mounted as the lower layer of an overlayfs, with this as the upper layer.
    /// All writes will go to this layer instead of the rootfs.
    ///
    /// Note: The `destination` field of this mount is ignored as mounting is handled internally.
    public let writableLayer: Mount?

    /// Configuration for the container.
    public let config: Configuration

    /// The configuration for the LinuxContainer.
    public struct Configuration: Sendable {
        /// Configuration for the init process of the container.
        public var process = LinuxProcessConfiguration()
        /// The amount of cpus for the container.
        public var cpus: Int = 4
        /// The memory in bytes to give to the container.
        public var memoryInBytes: UInt64 = 1024.mib()
        /// The hostname for the container.
        public var hostname: String?
        /// The system control options for the container.
        public var sysctl: [String: String] = [:]
        /// The network interfaces for the container.
        public var interfaces: [any Interface] = []
        /// The Unix domain socket relays to setup for the container.
        public var sockets: [UnixSocketConfiguration] = []
        /// The mounts for the container.
        public var mounts: [Mount] = LinuxContainer.defaultMounts()
        /// Paths inside the container that vmexec hides from the workload.
        /// Defaults to the OCI standard set (``LinuxContainer/defaultMaskedPaths()``),
        /// matching the restricted capability baseline. Set to `[]` to opt out,
        /// or append to extend it.
        public var maskedPaths: [String] = LinuxContainer.defaultMaskedPaths()
        /// Paths inside the container that vmexec marks read-only.
        /// Defaults to the OCI standard set (``LinuxContainer/defaultReadonlyPaths()``),
        /// matching the restricted capability baseline. Set to `[]` to opt out,
        /// or append to extend it.
        public var readonlyPaths: [String] = LinuxContainer.defaultReadonlyPaths()
        /// The DNS configuration for the container.
        public var dns: DNS?
        /// The hosts to add to /etc/hosts for the container.
        public var hosts: Hosts?
        /// Enable nested virtualization support.
        public var virtualization: Bool = false
        /// Optional destination for serial boot logs.
        public var bootLog: BootLog?
        /// EXPERIMENTAL: Path in the root filesystem for the virtual
        /// machine where the OCI runtime used to spawn the container lives.
        public var ociRuntimePath: String?
        /// Run the container with a minimal init process that handles signal
        /// forwarding and zombie reaping.
        public var useInit: Bool = false
        /// Programs the runtime runs at points in the container's lifecycle,
        /// as described by the runtime specification.
        ///
        /// The paths are resolved inside the guest, because that is where the
        /// runtime that would run them lives.
        ///
        /// NOTE: these reach the bundle's config.json but are only acted on
        /// when the container runs under an external OCI runtime. The default
        /// launcher is not one, so they have no effect on that path.
        public var hooks: ContainerizationOCI.Hooks? = nil
        /// Additional CPU cores to allocate for the virtual machine on top
        /// of the container's configured `cpus` value.
        public var cpuOverhead: Int = 1
        /// Additional memory in bytes to allocate for the virtual machine
        /// on top of the container's configured `memoryInBytes` value.
        /// The total is aligned to a 1 MiB boundary.
        public var memoryOverhead: UInt64 = 128.mib()

        /// Optional swap area for the container, as a block device mount.
        ///
        /// Swap lets a workload whose resident set exceeds `memoryInBytes`
        /// reclaim rather than meet the out of memory killer. The area is a
        /// block device rather than a file in the guest, because no filesystem
        /// the agent can write to exists when the sandbox starts: its root is
        /// mounted read only. The `destination` field is ignored, as the area
        /// is enabled rather than mounted.
        public var swapLayer: Mount? = nil

        public init() {}

        public init(
            process: LinuxProcessConfiguration,
            cpus: Int = 4,
            memoryInBytes: UInt64 = 1024.mib(),
            hostname: String? = nil,
            sysctl: [String: String] = [:],
            interfaces: [any Interface] = [],
            sockets: [UnixSocketConfiguration] = [],
            mounts: [Mount] = LinuxContainer.defaultMounts(),
            maskedPaths: [String] = LinuxContainer.defaultMaskedPaths(),
            readonlyPaths: [String] = LinuxContainer.defaultReadonlyPaths(),
            dns: DNS? = nil,
            hosts: Hosts? = nil,
            virtualization: Bool = false,
            bootLog: BootLog? = nil,
            ociRuntimePath: String? = nil,
            useInit: Bool = false,
            cpuOverhead: Int = 1,
            memoryOverhead: UInt64 = 128.mib()
        ) {
            self.process = process
            self.cpus = cpus
            self.memoryInBytes = memoryInBytes
            self.hostname = hostname
            self.sysctl = sysctl
            self.interfaces = interfaces
            self.sockets = sockets
            self.mounts = mounts
            self.maskedPaths = maskedPaths
            self.readonlyPaths = readonlyPaths
            self.dns = dns
            self.hosts = hosts
            self.virtualization = virtualization
            self.bootLog = bootLog
            self.ociRuntimePath = ociRuntimePath
            self.useInit = useInit
            self.cpuOverhead = cpuOverhead
            self.memoryOverhead = memoryOverhead
        }
    }

    private let state: AsyncMutex<State>

    // Ports to be allocated from for stdio and for
    // unix socket relays that are sharing a guest
    // uds to the host.
    private let hostVsockPorts: Atomic<UInt32>
    // Ports we request the guest to allocate for unix socket relays from
    // the host.
    private let guestVsockPorts: Atomic<UInt32>

    // Queue for copy IO.
    private let copyQueue = DispatchQueue(label: "com.apple.containerization.copy")

    private enum State: Sendable {
        /// The container class has been created but no live resources are running.
        case initialized
        /// The container's virtual machine has been setup and the runtime environment has been configured.
        case created(CreatedState)
        /// The initial process of the container has started and is running.
        case started(StartedState)
        /// The container has run and fully stopped.
        case stopped
        /// An error occurred during the lifetime of this class.
        case errored(Swift.Error)
        /// The container is paused.
        case paused(PausedState)

        struct CreatedState: Sendable {
            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager
            var fileMountContext: FileMountContext
        }

        struct StartedState: Sendable {
            let vm: any VirtualMachineInstance
            let process: LinuxProcess
            let relayManager: UnixSocketRelayManager
            var vendedProcesses: [String: LinuxProcess]
            let fileMountContext: FileMountContext

            init(_ state: CreatedState, process: LinuxProcess) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = process
                self.vendedProcesses = [:]
                self.fileMountContext = state.fileMountContext
            }

            init(_ state: PausedState) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = state.process
                self.vendedProcesses = state.vendedProcesses
                self.fileMountContext = state.fileMountContext
            }
        }

        struct PausedState: Sendable {
            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager
            let process: LinuxProcess
            var vendedProcesses: [String: LinuxProcess]
            let fileMountContext: FileMountContext

            init(_ state: StartedState) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = state.process
                self.vendedProcesses = state.vendedProcesses
                self.fileMountContext = state.fileMountContext
            }
        }

        func createdState(_ operation: String) throws -> CreatedState {
            switch self {
            case .created(let state):
                return state
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to \(operation): container must be created"
                )
            }
        }

        func startedState(_ operation: String) throws -> StartedState {
            switch self {
            case .started(let state):
                return state
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to \(operation): container must be running"
                )
            }
        }

        func pausedState(_ operation: String) throws -> PausedState {
            switch self {
            case .paused(let state):
                return state
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to \(operation): container must be paused"
                )
            }
        }

        mutating func validateForCreate() throws {
            switch self {
            case .initialized, .stopped:
                break
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container must be in initialized or stopped state to create"
                )
            }
        }

        mutating func setErrored(error: Swift.Error) {
            self = .errored(error)
        }

        func vm(_ operation: String) throws -> any VirtualMachineInstance {
            switch self {
            case .created(let state):
                return state.vm
            case .started(let state):
                return state.vm
            case .paused(let state):
                return state.vm
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to \(operation): container must be created, running, or paused"
                )
            }
        }
    }

    private let vmm: VirtualMachineManager
    private let logger: Logger?

    /// Create a new `LinuxContainer`.
    ///
    /// - Parameters:
    ///   - id: The identifier for the container.
    ///   - rootfs: The root filesystem mount containing the container image contents.
    ///     The `destination` field is ignored as mounting is handled internally.
    ///   - writableLayer: Optional writable layer mount. When provided, an overlayfs is used with
    ///     rootfs as the lower layer and this as the upper layer. Must be a block device.
    ///     The `destination` field is ignored as mounting is handled internally.
    ///   - vmm: The virtual machine manager that will handle launching the VM for the container.
    ///   - logger: Optional logger for container operations.
    ///   - configuration: A closure that configures the container by modifying the Configuration instance.
    public convenience init(
        _ id: String,
        rootfs: Mount,
        writableLayer: Mount? = nil,
        vmm: VirtualMachineManager,
        logger: Logger? = nil,
        configuration: (inout Configuration) throws -> Void
    ) throws {
        var config = Configuration()
        try configuration(&config)
        try self.init(
            id,
            rootfs: rootfs,
            writableLayer: writableLayer,
            vmm: vmm,
            configuration: config,
            logger: logger
        )
    }

    /// Create a new `LinuxContainer`.
    ///
    /// - Parameters:
    ///   - id: The identifier for the container.
    ///   - rootfs: The root filesystem mount containing the container image contents.
    ///     The `destination` field is ignored as mounting is handled internally.
    ///   - writableLayer: Optional writable layer mount. When provided, an overlayfs is used with
    ///     rootfs as the lower layer and this as the upper layer. Must be a block device.
    ///     The `destination` field is ignored as mounting is handled internally.
    ///   - vmm: The virtual machine manager that will handle launching the VM for the container.
    ///   - configuration: The container configuration specifying process, resources, networking, and other settings.
    ///   - logger: Optional logger for container operations.
    public init(
        _ id: String,
        rootfs: Mount,
        writableLayer: Mount? = nil,
        vmm: VirtualMachineManager,
        configuration: LinuxContainer.Configuration,
        logger: Logger? = nil
    ) throws {
        guard id.count <= Self.maxIDLength else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container id length \(id.count) exceeds maximum of \(Self.maxIDLength) characters"
            )
        }
        if let writableLayer {
            guard writableLayer.isBlock else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "writableLayer must be a block device"
                )
            }
        }
        self.id = id
        self.vmm = vmm
        self.hostVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.guestVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.logger = logger
        self.config = configuration
        self.state = AsyncMutex(.initialized)
        self.rootfs = rootfs
        self.writableLayer = writableLayer
    }

    private static func createDefaultRuntimeSpec(_ id: String) -> Spec {
        .init(
            process: .init(),
            hostname: id,
            root: .init(
                path: Self.guestRootfsPath(id),
                readonly: false
            ),
            linux: .init(
                resources: .init(),
                cgroupsPath: "/container/\(id)"
            )
        )
    }

    private func generateRuntimeSpec() -> Spec {
        var spec = Self.createDefaultRuntimeSpec(id)

        // Process toggles.
        spec.process = config.process.toOCI()

        spec.hooks = config.hooks

        // Wrap with init process if requested.
        if config.useInit {
            let originalArgs = spec.process?.args ?? []
            spec.process?.args = ["/.cz-init", "--"] + originalArgs
        }

        // General toggles.
        if let hostname = config.hostname {
            spec.hostname = hostname
        }

        // Linux toggles.
        spec.linux?.sysctl = config.sysctl
        spec.linux?.maskedPaths = config.maskedPaths
        spec.linux?.readonlyPaths = config.readonlyPaths

        // If the rootfs was requested as read-only, set it in the OCI spec.
        // We let the OCI runtime remount as ro, instead of doing it originally.
        // However, if we have a writable layer, the overlay allows writes so we don't mark it read-only.
        spec.root?.readonly = self.rootfs.options.contains("ro") && self.writableLayer == nil

        // Resource limits.
        // CPU: quota/period model where period is 100ms (100,000µs) and quota is cpus * period
        // Memory: limit in bytes
        spec.linux?.resources = LinuxResources(
            memory: LinuxMemory(
                limit: Int64(config.memoryInBytes)
            ),
            cpu: LinuxCPU(
                quota: Int64(config.cpus * 100_000),
                period: 100_000
            )
        )

        spec.linux?.namespaces = [
            LinuxNamespace(type: .cgroup),
            LinuxNamespace(type: .ipc),
            LinuxNamespace(type: .mount),
            LinuxNamespace(type: .pid),
            LinuxNamespace(type: .uts),
        ]

        return spec
    }

    /// The default set of mounts for a LinuxContainer.
    public static func defaultMounts() -> [Mount] {
        let defaultOptions = ["nosuid", "noexec", "nodev"]
        return [
            .any(type: "proc", source: "proc", destination: "/proc"),
            .any(type: "sysfs", source: "sysfs", destination: "/sys", options: defaultOptions),
            .any(type: "devtmpfs", source: "none", destination: "/dev", options: ["nosuid", "mode=755"]),
            .any(type: "mqueue", source: "mqueue", destination: "/dev/mqueue", options: defaultOptions),
            .any(type: "tmpfs", source: "tmpfs", destination: "/dev/shm", options: defaultOptions + ["mode=1777", "size=65536k"]),
            .any(type: "cgroup2", source: "none", destination: "/sys/fs/cgroup", options: defaultOptions),
            .any(type: "devpts", source: "devpts", destination: "/dev/pts", options: ["nosuid", "noexec", "newinstance", "gid=5", "mode=0620", "ptmxmode=0666"]),
        ]
    }

    /// The default set of paths to mask inside a container, matching the OCI
    /// runtime spec defaults that runc and other production runtimes apply.
    /// Each path is hidden from the workload (replaced by `/dev/null` for files
    /// or an empty tmpfs for directories) by `vmexec` after `pivot_root`.
    ///
    /// Applied by default (see ``Configuration/maskedPaths``); set
    /// `config.maskedPaths = []` to opt out, or append to extend the set.
    public static func defaultMaskedPaths() -> [String] {
        [
            "/proc/asound",
            "/proc/acpi",
            "/proc/kcore",
            "/proc/keys",
            "/proc/latency_stats",
            "/proc/timer_list",
            "/proc/timer_stats",
            "/proc/sched_debug",
            "/proc/scsi",
            "/sys/firmware",
            "/sys/devices/virtual/powercap",
        ]
    }

    /// The default set of paths to mark read-only inside a container, matching
    /// the OCI runtime spec defaults that runc and other production runtimes apply.
    ///
    /// Applied by default (see ``Configuration/readonlyPaths``); set
    /// `config.readonlyPaths = []` to opt out, or append to extend the set.
    public static func defaultReadonlyPaths() -> [String] {
        [
            "/proc/bus",
            "/proc/fs",
            "/proc/irq",
            "/proc/sys",
            "/proc/sysrq-trigger",
        ]
    }

    /// A more traditional default set of mounts that OCI runtimes typically employ.
    public static func defaultOCIMounts() -> [Mount] {
        let defaultOptions = ["nosuid", "noexec", "nodev"]
        return [
            .any(type: "proc", source: "proc", destination: "/proc"),
            .any(type: "tmpfs", source: "tmpfs", destination: "/dev", options: ["nosuid", "mode=755", "size=65536k"]),
            .any(type: "devpts", source: "devpts", destination: "/dev/pts", options: ["nosuid", "noexec", "newinstance", "gid=5", "mode=0620", "ptmxmode=0666"]),
            .any(type: "sysfs", source: "sysfs", destination: "/sys", options: defaultOptions),
            .any(type: "mqueue", source: "mqueue", destination: "/dev/mqueue", options: defaultOptions),
            .any(type: "tmpfs", source: "tmpfs", destination: "/dev/shm", options: defaultOptions + ["mode=1777", "size=65536k"]),
            .any(type: "cgroup2", source: "none", destination: "/sys/fs/cgroup", options: defaultOptions),
        ]
    }

    private static func guestRootfsPath(_ id: String) -> String {
        "/run/container/\(id)/rootfs"
    }

    private static func guestSocketStagingPath(_ socketID: String) -> String {
        "/run/sockets/\(socketID).sock"
    }
}

extension LinuxContainer {
    package var root: String {
        Self.guestRootfsPath(id)
    }

    /// Number of CPU cores allocated.
    public var cpus: Int {
        config.cpus
    }

    /// Amount of memory in bytes allocated for the container.
    /// This will be aligned to a 1MB boundary if it isn't already.
    public var memoryInBytes: UInt64 {
        config.memoryInBytes
    }

    /// Network interfaces of the container.
    public var interfaces: [any Interface] {
        config.interfaces
    }

    /// Enable the container's swap area, if it has one.
    ///
    /// The device is attached with the container's other block devices, so the
    /// agent is told the guest path the VMM allocated it. It is enabled rather
    /// than mounted, which is why it travels as a mount of type `swap`.
    private func enableSwap(
        attached: ContainerAttachments,
        agent: VirtualMachineAgent
    ) async throws {
        guard self.config.swapLayer != nil else {
            return
        }
        guard let swap = attached.swap else {
            throw ContainerizationError(.notFound, message: "swap mount not found")
        }
        try await agent.mount(
            ContainerizationOCI.Mount(
                type: Swap.mountType,
                source: swap.source,
                destination: "",
                options: swap.options
            ))
    }

    private func mountRootfs(
        attached: ContainerAttachments,
        rootfsPath: String,
        agent: VirtualMachineAgent
    ) async throws {
        if let writableAttachment = attached.writableLayer {
            try await agent.mountOverlayRootfs(
                containerID: self.id,
                rootfsAttachment: attached.rootfs,
                writableAttachment: writableAttachment,
                rootfsPath: rootfsPath
            )
        } else {
            // No writable layer. Mount rootfs directly.
            var rootfs = attached.rootfs.to
            rootfs.destination = rootfsPath
            try await agent.mount(rootfs)
        }
    }

    /// Create and start the underlying container's virtual machine
    /// and set up the runtime environment. The container's init process
    /// is NOT running afterwards.
    public func create() async throws {
        try await self.state.withLock { state in
            try state.validateForCreate()

            // This is a bit of an annoyance, but because the type we use for the rootfs is simply
            // the same Mount type we use for non-rootfs mounts, it's possible someone passed 'ro'
            // in the options (which should be perfectly valid). However, the problem is when we go to
            // setup /etc/hosts and /etc/resolv.conf, as we'd get EROFS if they did supply 'ro'.
            // To remedy this, remove any "ro" options before passing to VZ. Having the OCI runtime
            // remount "ro" (which is what we do later in the guest) is truthfully the right thing,
            // but this bit here is just a tad awkward.
            var modifiedRootfs = self.rootfs
            modifiedRootfs.options.removeAll(where: { $0 == "ro" })

            let vmMemory = self.memoryInBytes + self.config.memoryOverhead

            let vmCpus = self.cpus + self.config.cpuOverhead

            // Prepare file mounts. This transforms single-file mounts into directory shares.
            let fileMountContext = try FileMountContext.prepare(mounts: self.config.mounts)
            // This is dumb, but alas.
            let fileMountContextHolder = Mutex<FileMountContext>(fileMountContext)

            // Build the container's storage to attach to the VM. The swap
            // device is attached with the container's other block devices so
            // the guest is told the /dev path the VMM allocates it.
            let containerStorage = ContainerMounts(
                rootfs: modifiedRootfs,
                writableLayer: self.writableLayer,
                swap: self.config.swapLayer,
                mounts: fileMountContext.transformedMounts
            )

            let vmConfig = VMConfiguration(
                cpus: vmCpus,
                memoryInBytes: vmMemory,
                interfaces: self.interfaces,
                storage: MachineMounts(containers: [self.id: containerStorage]),
                bootLog: self.config.bootLog,
                nestedVirtualization: self.config.virtualization
            )
            let creationConfig = StandardVMConfig(configuration: vmConfig)
            let vm = try await self.vmm.create(config: creationConfig)
            let relayManager = UnixSocketRelayManager(vm: vm, log: self.logger)

            try await vm.start()
            do {
                let storageForAgent = containerStorage
                try await vm.withAgent { agent in
                    try await agent.standardSetup()

                    // Mount the unified virtiofs share at /run/virtiofs only
                    // when at least one of the container's mounts is virtiofs
                    // — the bind-mount transform below derives its sources
                    // from /run/virtiofs/{tag}, so the unified share is only
                    // load-bearing when there are virtiofs mounts. The macOS
                    // VZ backend always exposes the virtiofs device (even
                    // with zero shares), but the cloud-hypervisor backend
                    // only spawns virtiofsd when shares exist; mounting an
                    // unbacked tag fails with EINVAL.
                    let hasVirtiofsMount = storageForAgent.all.contains { mount in
                        if case .virtiofs = mount.runtimeOptions { return true }
                        return false
                    }
                    if hasVirtiofsMount {
                        // VZ exposes ONE virtio-fs device with tag "virtiofs"
                        // and multiple sources as subdirs (VZMultipleDirectoryShare).
                        // The CH backend exposes one device per source-hash
                        // tag instead, so the guest must mount each tag
                        // separately at /run/virtiofs/<tag>. The bind-mount
                        // transform below uses /run/virtiofs/<tag> in both
                        // cases, so this branch is only about how /run/virtiofs
                        // gets populated.
                        if vm.virtiofsLayout == .perTag {
                            try await agent.mkdir(path: "/run/virtiofs", all: true, perms: 0o755)
                            let virtiofsAttachments = (vm.storage.containers[self.id]?.all ?? []).filter { $0.type == "virtiofs" }
                            let uniqueTags = Set(virtiofsAttachments.map(\.source))
                            for tag in uniqueTags {
                                let dest = "/run/virtiofs/\(tag)"
                                try await agent.mkdir(path: dest, all: true, perms: 0o755)
                                try await agent.mount(
                                    ContainerizationOCI.Mount(
                                        type: "virtiofs",
                                        source: tag,
                                        destination: dest,
                                        options: []
                                    ))
                            }
                        } else {
                            try await agent.mount(
                                ContainerizationOCI.Mount(
                                    type: "virtiofs",
                                    source: "virtiofs",
                                    destination: "/run/virtiofs",
                                    options: []
                                ))
                        }
                    }

                    guard let attached = vm.storage.containers[self.id] else {
                        throw ContainerizationError(.notFound, message: "rootfs mount not found")
                    }
                    let rootfsPath = Self.guestRootfsPath(self.id)
                    try await self.mountRootfs(attached: attached, rootfsPath: rootfsPath, agent: agent)
                    try await self.enableSwap(attached: attached, agent: agent)

                    // Mount file mount holding directories under /run.
                    if fileMountContext.hasFileMounts {
                        var ctx = fileMountContextHolder.withLock { $0 }
                        try await ctx.mountHoldingDirectories(
                            vmMounts: attached.mounts,
                            agent: agent
                        )
                        fileMountContextHolder.withLock { $0 = ctx }
                    }

                    // Start up our friendly unix socket relays.
                    for socket in self.config.sockets {
                        try await self.relayUnixSocket(
                            socket: socket,
                            relayManager: relayManager,
                            agent: agent
                        )
                    }

                    // For every interface asked for:
                    // 1. Add the address requested
                    // 2. Online the adapter
                    // 3. For the first interface, add the default route
                    var defaultRouteSet = false
                    for (index, i) in self.interfaces.enumerated() {
                        let name = "eth\(index)"
                        try await agent.setupInterface(
                            i,
                            name: name,
                            setDefaultRoute: !defaultRouteSet,
                            logger: self.logger
                        )
                        defaultRouteSet = true
                    }

                    // Setup /etc/resolv.conf and /etc/hosts if asked for.
                    if let dns = self.config.dns {
                        try await agent.configureDNS(config: dns, location: rootfsPath)
                    }
                    if let hosts = self.config.hosts {
                        try await agent.configureHosts(config: hosts, location: rootfsPath)
                    }

                }
                state = .created(.init(vm: vm, relayManager: relayManager, fileMountContext: fileMountContextHolder.withLock { $0 }))
            } catch {
                try? await relayManager.stopAll()
                try? await vm.stop()
                state.setErrored(error: error)
                throw error
            }
        }
    }

    /// Start the container's initial process.
    public func start() async throws {
        try await self.state.withLock { state in
            let createdState = try state.createdState("start")

            let agent = try await createdState.vm.dialAgent()
            do {
                var spec = self.generateRuntimeSpec()
                // Filter out file mount holding directories. We'll mount those separately under /run.
                // Transform virtiofs mounts to bind mounts from /run/virtiofs/{tag}
                let containerMounts = createdState.vm.storage.containers[self.id]?.mounts ?? []
                let holdingTags = createdState.fileMountContext.holdingDirectoryTags
                var mounts: [ContainerizationOCI.Mount] =
                    containerMounts
                    .filter { !holdingTags.contains($0.source) }
                    .map { attached -> ContainerizationOCI.Mount in
                        if attached.type == "virtiofs" {
                            // Transform to bind mount from holding directory
                            return ContainerizationOCI.Mount(
                                type: "none",
                                source: "/run/virtiofs/\(attached.source)",
                                destination: attached.destination,
                                options: ["bind"] + attached.options
                            )
                        }
                        return attached.to
                    }
                    + createdState.fileMountContext.ociBindMounts()

                // When useInit is enabled, bind mount vminitd from the VM's filesystem
                // into the container so it can be executed.
                if self.config.useInit {
                    mounts.append(
                        ContainerizationOCI.Mount(
                            type: "bind",
                            source: "/sbin/vminitd",
                            destination: "/.cz-init",
                            options: ["bind", "ro"]
                        ))
                }

                // Bind mount staged sockets into the container. Sockets relayed
                // .into the container are created in a staging directory outside
                // the rootfs to avoid symlink traversal and mount shadowing.
                for socket in self.config.sockets where socket.direction == .into {
                    mounts.append(
                        ContainerizationOCI.Mount(
                            type: "bind",
                            source: Self.guestSocketStagingPath(socket.id),
                            destination: socket.destination.path,
                            options: ["bind"]
                        ))
                }

                spec.mounts = cleanAndSortMounts(mounts)

                let stdio = IOUtil.setup(
                    portAllocator: self.hostVsockPorts,
                    stdin: self.config.process.stdin,
                    stdout: self.config.process.stdout,
                    stderr: self.config.process.stderr
                )

                let process = LinuxProcess(
                    self.id,
                    containerID: self.id,
                    spec: spec,
                    io: stdio,
                    ociRuntimePath: self.config.ociRuntimePath,
                    agent: agent,
                    vm: createdState.vm,
                    logger: self.logger
                )
                try await process.start()

                state = .started(.init(createdState, process: process))
            } catch {
                try? await agent.close()
                try? await createdState.vm.stop()
                state.setErrored(error: error)
                throw error
            }
        }
    }

    /// Stop the container from executing. This MUST be called even if wait() has returned
    /// as their are additional resources to free.
    public func stop() async throws {
        try await self.state.withLock { state in
            // Allow stop to be called multiple times.
            if case .stopped = state {
                return
            }

            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager

            let startedState = try? state.startedState("stop")
            if let startedState {
                vm = startedState.vm
                relayManager = startedState.relayManager
            } else {
                let createdState = try state.createdState("stop")
                vm = createdState.vm
                relayManager = createdState.relayManager
            }

            var firstError: Error?
            do {
                try await relayManager.stopAll()
            } catch {
                self.logger?.error("failed to stop relay manager: \(error)")
                firstError = firstError ?? error
            }

            do {
                try await vm.withAgent { agent in
                    // First, we need to stop any unix socket relays as this will
                    // keep the rootfs from being able to umount (EBUSY).
                    let sockets = self.config.sockets
                    if !sockets.isEmpty {
                        guard let relayAgent = agent as? SocketRelayAgent else {
                            throw ContainerizationError(
                                .unsupported,
                                message: "VirtualMachineAgent does not support relaySocket surface"
                            )
                        }
                        for socket in sockets {
                            try await relayAgent.stopSocketRelay(configuration: socket)
                        }
                    }

                    if let _ = startedState {
                        // Now lets ensure every process is donezo.
                        try await agent.kill(pid: -1, signal: SIGKILL)

                        // Wait on init proc exit. Give it 5 seconds of leeway.
                        _ = try await agent.waitProcess(
                            id: self.id,
                            containerID: self.id,
                            timeoutInSeconds: 5
                        )
                    }

                    // Today, we leave EBUSY looping and other fun logic up to the
                    // guest agent.
                    try await agent.umount(
                        path: Self.guestRootfsPath(self.id),
                        flags: 0
                    )

                    // If we have a writable layer, we also need to unmount the lower and upper layers.
                    if self.writableLayer != nil {
                        let upperPath = "/run/container/\(self.id)/upper"
                        let lowerPath = "/run/container/\(self.id)/lower"
                        try await agent.umount(path: upperPath, flags: 0)
                        try await agent.umount(path: lowerPath, flags: 0)
                    }

                    try await agent.sync()
                }
            } catch {
                self.logger?.error("failed during guest cleanup: \(error)")
                firstError = firstError ?? error
            }

            if let startedState {
                for process in startedState.vendedProcesses.values {
                    do {
                        try await process._delete()
                    } catch {
                        self.logger?.error("failed to delete process \(process.id): \(error)")
                        firstError = firstError ?? error
                    }
                }

                do {
                    try await startedState.process.delete()
                } catch {
                    self.logger?.error("failed to delete init process: \(error)")
                    firstError = firstError ?? error
                }
            }

            do {
                try await vm.stop()
                state = .stopped
                if let firstError {
                    throw firstError
                }
            } catch {
                self.logger?.error("failed to stop VM: \(error)")
                let finalError = firstError ?? error
                state.setErrored(error: finalError)
                throw finalError
            }
        }
    }

    /// Send a signal to the container.
    public func kill(_ signal: Signal) async throws {
        try await self.state.withLock {
            let state = try $0.startedState("kill")
            try await state.process.kill(signal)
        }
    }

    /// Wait for the container to exit. Returns the exit code.
    @discardableResult
    public func wait(timeoutInSeconds: Int64? = nil) async throws -> ExitStatus {
        let t = try await self.state.withLock {
            let state = try $0.startedState("wait")
            let t = Task {
                try await state.process.wait(timeoutInSeconds: timeoutInSeconds)
            }
            return t
        }
        return try await t.value
    }

    /// Resize the container's terminal (if one was requested). This
    /// will error if terminal was set to false before creating the container.
    public func resize(to: Terminal.Size) async throws {
        try await self.state.withLock {
            let state = try $0.startedState("resize")
            try await state.process.resize(to: to)
        }
    }

    /// Execute a new process in the container. The process is not started after this call, and must be manually started
    /// via the `start` method.
    public func exec(_ id: String, configuration: @Sendable @escaping (inout LinuxProcessConfiguration) throws -> Void) async throws -> LinuxProcess {
        try await self.state.withLock { state in
            var startedState = try state.startedState("exec")

            var spec = self.generateRuntimeSpec()
            var config = LinuxProcessConfiguration()
            try configuration(&config)
            spec.process = config.toOCI()

            let stdio = IOUtil.setup(
                portAllocator: self.hostVsockPorts,
                stdin: config.stdin,
                stdout: config.stdout,
                stderr: config.stderr
            )
            let agent = try await startedState.vm.dialAgent()
            let process = LinuxProcess(
                id,
                containerID: self.id,
                spec: spec,
                io: stdio,
                ociRuntimePath: self.config.ociRuntimePath,
                agent: agent,
                vm: startedState.vm,
                logger: self.logger,
                onDelete: { [weak self = self] in
                    await self?.removeProcess(id: id)
                }
            )

            startedState.vendedProcesses[id] = process
            state = .started(startedState)

            return process
        }
    }

    /// Execute a new process in the container. The process is not started after this call, and must be manually started
    /// via the `start` method.
    public func exec(_ id: String, configuration: LinuxProcessConfiguration) async throws -> LinuxProcess {
        try await self.state.withLock {
            var state = try $0.startedState("exec")

            var spec = self.generateRuntimeSpec()
            spec.process = configuration.toOCI()

            let stdio = IOUtil.setup(
                portAllocator: self.hostVsockPorts,
                stdin: configuration.stdin,
                stdout: configuration.stdout,
                stderr: configuration.stderr
            )
            let agent = try await state.vm.dialAgent()
            let process = LinuxProcess(
                id,
                containerID: self.id,
                spec: spec,
                io: stdio,
                ociRuntimePath: self.config.ociRuntimePath,
                agent: agent,
                vm: state.vm,
                logger: self.logger,
                onDelete: { [weak self = self] in
                    await self?.removeProcess(id: id)
                }
            )

            state.vendedProcesses[id] = process
            $0 = .started(state)

            return process
        }
    }

    /// Dial a vsock port in the container.
    public func dialVsock(port: UInt32) async throws -> FileHandle {
        try await self.state.withLock {
            let state = try $0.startedState("dialVsock")
            return try await state.vm.dial(port)
        }
    }

    /// Provides scoped access to the underlying virtual machine instance.
    ///
    /// Most users should prefer the higher level APIs on ``LinuxContainer``
    /// directly. This is intended for advanced use cases that need to interact
    /// with the virtual machine outside of the container abstraction.
    public func withVirtualMachineInstance<T: Sendable>(
        _ fn: @Sendable (any VirtualMachineInstance) async throws -> T
    ) async throws -> T {
        let vm = try await self.state.withLock { state in
            try state.vm("withVirtualMachineInstance")
        }
        return try await fn(vm)
    }

    /// Close the containers standard input to signal no more input is
    /// arriving.
    public func closeStdin() async throws {
        try await self.state.withLock {
            let state = try $0.startedState("closeStdin")
            return try await state.process.closeStdin()
        }
    }

    /// Remove a process from the vended processes tracking.
    private func removeProcess(id: String) async {
        await self.state.withLock {
            guard case .started(var state) = $0 else {
                return
            }
            state.vendedProcesses.removeValue(forKey: id)
            $0 = .started(state)
        }
    }

    /// Get statistics for the container.
    public func statistics(categories: StatCategory = .all) async throws -> ContainerStatistics {
        try await self.state.withLock {
            let state = try $0.startedState("statistics")

            let stats = try await state.vm.withAgent { agent in
                let allStats = try await agent.containerStatistics(containerIDs: [self.id], categories: categories)
                guard let containerStats = allStats.first else {
                    throw ContainerizationError(
                        .notFound,
                        message: "statistics for container \(self.id) not found"
                    )
                }
                return containerStats
            }

            return stats
        }
    }

    // Perform filesystem operations in the container.
    public func filesystemOperation(operation: FilesystemOperation, path: String) async throws {
        try await self.state.withLock {
            let state = try $0.startedState("filesystemOperation")
            try await state.vm.withAgent { agent in
                guard let vminitd = agent as? Vminitd else {
                    throw ContainerizationError(.unsupported, message: "filesystemOperation requires Vminitd agent")
                }
                let guestPath = URL(filePath: Self.guestRootfsPath(self.id)).appending(path: path).path
                try await vminitd.filesystemOperation(operation: operation, path: guestPath)
            }
        }
    }

    private func relayUnixSocket(
        socket: UnixSocketConfiguration,
        relayManager: UnixSocketRelayManager,
        agent: any VirtualMachineAgent
    ) async throws {
        guard let relayAgent = agent as? SocketRelayAgent else {
            throw ContainerizationError(
                .unsupported,
                message: "VirtualMachineAgent does not support relaySocket surface"
            )
        }

        var socket = socket
        let rootInGuest = URL(filePath: self.root)

        let port: UInt32
        if socket.direction == .into {
            port = self.hostVsockPorts.wrappingAdd(1, ordering: .relaxed).oldValue
            socket.destination = URL(filePath: Self.guestSocketStagingPath(socket.id))
        } else {
            port = self.guestVsockPorts.wrappingAdd(1, ordering: .relaxed).oldValue
            socket.source = rootInGuest.appending(path: socket.source.path)
        }

        try await relayManager.start(port: port, socket: socket)
        try await relayAgent.relaySocket(port: port, configuration: socket)
    }

    /// Default chunk size for file transfers (1MiB).
    public static let defaultCopyChunkSize = GuestFileTransfer.defaultChunkSize

    /// Copy a file or directory from the host into the container.
    ///
    /// Data transfer happens over a dedicated vsock connection. For directories,
    /// the source is archived as tar+gzip and streamed directly through vsock
    /// without intermediate temp files.
    public func copyIn(
        from source: URL,
        to destination: URL,
        mode: UInt32 = 0o644,
        createParents: Bool = true,
        chunkSize: Int = defaultCopyChunkSize
    ) async throws {
        try await self.state.withLock {
            let state = try $0.startedState("copyIn")
            try await self.transfer(vm: state.vm).copyIn(
                from: source,
                to: destination,
                mode: mode,
                createParents: createParents,
                chunkSize: chunkSize
            )
        }
    }

    /// Copy a file or directory from the container to the host.
    ///
    /// Data transfer happens over a dedicated vsock connection. For directories,
    /// the guest archives the source as tar+gzip and streams it directly through
    /// vsock. The host extracts the archive without intermediate temp files.
    public func copyOut(
        from source: URL,
        to destination: URL,
        createParents: Bool = true,
        chunkSize: Int = defaultCopyChunkSize
    ) async throws {
        try await self.state.withLock {
            let state = try $0.startedState("copyOut")
            try await self.transfer(vm: state.vm).copyOut(
                from: source,
                to: destination,
                createParents: createParents,
                chunkSize: chunkSize
            )
        }
    }

    /// A transfer against this container's filesystem, on a port of its own.
    private func transfer(vm: any VirtualMachineInstance) -> GuestFileTransfer {
        GuestFileTransfer(
            vm: vm,
            guestRoot: self.root,
            port: self.hostVsockPorts.wrappingAdd(1, ordering: .relaxed).oldValue,
            queue: self.copyQueue
        )
    }
}

extension VirtualMachineInstance {
    /// Scoped access to an agent instance to ensure the resources are always freed (mostly close(2)'ing
    /// the vsock fd)
    func withAgent<T>(fn: @Sendable (VirtualMachineAgent) async throws -> T) async throws -> T {
        let agent = try await self.dialAgent()
        do {
            let result = try await fn(agent)
            try await agent.close()
            return result
        } catch {
            try? await agent.close()
            throw error
        }
    }
}

extension AttachedFilesystem {
    var to: ContainerizationOCI.Mount {
        .init(
            type: self.type,
            source: self.source,
            destination: self.destination,
            options: self.options
        )
    }
}

/// Normalize mount destinations via ``FilePath/lexicallyNormalized()`` and
/// sort mounts by the depth of their destination path. This ensures that
/// higher level mounts don't shadow other mounts. For example, if a user
/// specifies mounts for `/tmp/foo/bar` and `/tmp`, sorting by depth ensures
/// `/tmp` is mounted first without shadowing `/tmp/foo/bar`.
func cleanAndSortMounts(_ mounts: [ContainerizationOCI.Mount]) -> [ContainerizationOCI.Mount] {
    var mounts = mounts
    for i in mounts.indices {
        mounts[i].destination = FilePath(mounts[i].destination).lexicallyNormalized().string
    }
    return sortMountsByDestinationDepth(mounts)
}

/// Sort mounts by the depth of their destination path.
func sortMountsByDestinationDepth(_ mounts: [ContainerizationOCI.Mount]) -> [ContainerizationOCI.Mount] {
    mounts.sorted { a, b in
        a.destination.split(separator: "/").count < b.destination.split(separator: "/").count
    }
}

struct IOUtil {
    static func setup(
        portAllocator: borrowing Atomic<UInt32>,
        stdin: ReaderStream?,
        stdout: Writer?,
        stderr: Writer?
    ) -> LinuxProcess.Stdio {
        var stdinSetup: LinuxProcess.StdioReaderSetup? = nil
        if let reader = stdin {
            let ret = portAllocator.wrappingAdd(1, ordering: .relaxed)
            stdinSetup = .init(
                port: ret.oldValue,
                reader: reader
            )
        }

        var stdoutSetup: LinuxProcess.StdioSetup? = nil
        if let writer = stdout {
            let ret = portAllocator.wrappingAdd(1, ordering: .relaxed)
            stdoutSetup = LinuxProcess.StdioSetup(
                port: ret.oldValue,
                writer: writer
            )
        }

        var stderrSetup: LinuxProcess.StdioSetup? = nil
        if let writer = stderr {
            let ret = portAllocator.wrappingAdd(1, ordering: .relaxed)
            stderrSetup = LinuxProcess.StdioSetup(
                port: ret.oldValue,
                writer: writer
            )
        }

        return LinuxProcess.Stdio(
            stdin: stdinSetup,
            stdout: stdoutSetup,
            stderr: stderrSetup
        )
    }
}
