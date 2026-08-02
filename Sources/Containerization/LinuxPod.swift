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
import Foundation
import Logging
import Synchronization

import struct ContainerizationOS.Swap
import struct ContainerizationOS.Terminal

/// NOTE: Experimental API
///
/// `LinuxPod` allows managing multiple Linux containers within a single
/// virtual machine. Each container has its own rootfs and process, but
/// shares the VM's resources (CPU, memory, network).
public final class LinuxPod: Sendable {
    static let maxIDLength = 64

    /// The identifier of the pod.
    public let id: String

    /// Configuration for the pod.
    public let config: Configuration

    /// The configuration for the LinuxPod.
    public struct Configuration: Sendable {
        /// The amount of cpus for the pod's VM.
        public var cpus: Int = 4
        /// The memory in bytes to give to the pod's VM.
        public var memoryInBytes: UInt64 = 1024.mib()
        /// Optional swap area shared by every container in the pod, as a block
        /// device mount.
        ///
        /// The area belongs to the pod rather than to any one container, so the
        /// guest kernel decides which container's pages are reclaimed to it.
        /// Containers are free to use all of it unless they carry a limit of
        /// their own. The `destination` field is ignored, as the area is
        /// enabled rather than mounted.
        public var swapLayer: Mount? = nil
        /// The network interfaces for the pod.
        public var interfaces: [any Interface] = []
        /// Whether nested virtualization should be turned on for the pod.
        public var virtualization: Bool = false
        /// Additional CPU cores to allocate for the virtual machine on top of
        /// the pod's configured `cpus`, so what the pod was given is what its
        /// containers have rather than what the guest agent leaves of it.
        public var cpuOverhead: Int = 1
        /// Additional memory in bytes to allocate for the virtual machine on
        /// top of the pod's configured `memoryInBytes`.
        public var memoryOverhead: UInt64 = 128.mib()
        /// Optional file path to store serial boot logs.
        public var bootLog: BootLog?
        /// Whether containers in the pod should share a PID namespace.
        /// When enabled, all containers can see each other's processes.
        public var shareProcessNamespace: Bool = false
        /// The default hostname for all containers in the pod.
        /// Individual containers can override this by setting their own `hostname` configuration.
        public var hostname: String?
        /// The default DNS configuration for all containers in the pod.
        /// Individual containers can override this by setting their own `dns` configuration.
        public var dns: DNS?
        /// The default hosts file configuration for all containers in the pod.
        /// Individual containers can override this by setting their own `hosts` configuration.
        public var hosts: Hosts?
        /// Volumes attached to the pod. Can be shared with multiple containers.
        public var volumes: [PodVolume] = []
        /// Extension objects that participate in the VM instance lifecycle.
        public var extensions: [any Sendable] = []

        public init() {}
    }

    /// Configuration for a container within the pod.
    public struct ContainerConfiguration: Sendable {
        /// Configuration for the init process of the container.
        public var process = LinuxProcessConfiguration()
        /// Optional per-container CPU limit (can exceed pod total for oversubscription).
        public var cpus: Int?
        /// Optional per-container memory limit in bytes (can exceed pod total for oversubscription).
        public var memoryInBytes: UInt64?
        /// Optional cap on how much of the pod's swap area this container may
        /// use, in bytes. Leaving it unset lets the container use the whole
        /// area, which is what containers sharing a pool usually want.
        ///
        /// This counts swap alone. The runtime spec carries memory and swap
        /// combined, so `memoryInBytes` is added to it when the spec is built,
        /// and a swap limit without a memory limit is rejected because the
        /// combined figure cannot be worked out without one.
        ///
        /// Kata and docker spell the same limit as the combined figure the spec
        /// carries, subtracting the memory limit to size the area, so a
        /// container asking there for 2 GiB against a 1 GiB memory limit is
        /// asking for 1 GiB of swap and here for 2 GiB. That figure suits a
        /// container whose swap is sized for it alone; this one is a share of
        /// an area the pod owns, and how much of that share a container may
        /// take is what the number says.
        /// https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-setup-swap-devices-in-guest-kernel.md
        public var swapInBytes: UInt64?
        /// The hostname for the container.
        public var hostname: String?
        /// The system control options for the container.
        public var sysctl: [String: String] = [:]
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
        /// The Unix domain socket relays to setup for the container.
        public var sockets: [UnixSocketConfiguration] = []
        /// The DNS configuration for the container.
        public var dns: DNS?
        /// The hosts file configuration for the container.
        public var hosts: Hosts?
        /// Run the container with a minimal init process that handles signal
        /// forwarding and zombie reaping.
        public var useInit: Bool = false
        /// EXPERIMENTAL: Path in the root filesystem for the virtual
        /// machine where the OCI runtime used to spawn the container lives.
        public var ociRuntimePath: String?
        /// Hooks the runtime specification carries for the container. An OCI
        /// runtime is what runs them, so they take effect for a container
        /// given an `ociRuntimePath`.
        public var hooks: ContainerizationOCI.Hooks? = nil

        public init() {}
    }

    /// A volume that is attached at the pod level and can be shared by multiple containers.
    public struct PodVolume: Sendable {
        /// Describes the backing storage for the volume.
        public enum Source: Sendable {
            /// A network block device (NBD) volume.
            case nbd(url: URL, timeout: TimeInterval? = nil, readOnly: Bool = false)
            /// A disk-image file on the host, attached as a virtio-block device.
            case diskImage(path: URL, readOnly: Bool = false)
            /// An in-memory (tmpfs) volume mounted inside the guest.
            case tmpfs(sizeBytes: UInt64? = nil)
        }

        /// The logical name of this volume. Containers reference this name
        /// via `Mount.sharedMount(name:destination:)` in their mounts.
        public var name: String
        /// The backing storage source for this volume.
        public var source: Source
        /// The filesystem format on the volume.
        public var format: String

        public init(name: String, source: Source, format: String) {
            self.name = name
            self.source = source
            self.format = format
        }

        func toMount() -> Mount {
            switch source {
            case .nbd(let url, let timeout, let readOnly):
                var runtimeOptions: [String] = []
                if let timeout {
                    runtimeOptions.append("vzTimeout=\(timeout)")
                }
                return Mount.block(
                    format: self.format,
                    source: url.absoluteString,
                    destination: LinuxPod.guestVolumePath(name),
                    options: readOnly ? ["ro"] : [],
                    runtimeOptions: runtimeOptions
                )
            case .diskImage(let path, let readOnly):
                return Mount.block(
                    format: self.format,
                    source: path.absolutePath(),
                    destination: LinuxPod.guestVolumePath(name),
                    options: readOnly ? ["ro"] : []
                )
            case .tmpfs(let sizeBytes):
                return Mount.any(
                    type: "tmpfs",
                    source: "tmpfs",
                    destination: LinuxPod.guestVolumePath(name),
                    options: sizeBytes.map { ["size=\($0)"] } ?? []
                )
            }
        }
    }

    private struct PodContainer: Sendable {
        let id: String
        let rootfs: Mount
        let writableLayer: Mount?
        let config: ContainerConfiguration
        var state: ContainerState
        var process: LinuxProcess?
        var fileMountContext: FileMountContext

        enum ContainerState: Sendable {
            case registered
            case created
            case started
            case stopped
            case errored
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

    // Where the blocking reads and writes of a file transfer run.
    private let copyQueue = DispatchQueue(label: "com.apple.containerization.copy")

    private struct State: Sendable {
        var phase: Phase
        var containers: [String: PodContainer]
        var pauseProcess: LinuxProcess?
        // Whether the unified virtiofs share is mounted at `/run/virtiofs` in the guest
        var unifiedVirtiofsMounted: Bool = false
    }

    private enum Phase: Sendable {
        /// The pod has been created but no live resources are running.
        case initialized
        /// The pod's virtual machine has been setup and the runtime environment has been configured.
        case created(CreatedState)
        /// An error occurred during the lifetime of this class.
        case errored(Swift.Error)

        struct CreatedState: Sendable {
            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager
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
                    message: "failed to \(operation): pod must be created"
                )
            }
        }

        mutating func validateForCreate() throws {
            switch self {
            case .initialized:
                break
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "pod must be in initialized state to create"
                )
            }
        }

        mutating func setErrored(error: Swift.Error) {
            self = .errored(error)
        }
    }

    private let vmm: VirtualMachineManager
    private let logger: Logger?

    /// Create a new `LinuxPod`. A `VirtualMachineManager` instance must be
    /// provided that will handle launching the virtual machine the containers
    /// will execute inside of.
    public init(
        _ id: String,
        vmm: VirtualMachineManager,
        logger: Logger? = nil,
        configuration: (inout Configuration) throws -> Void
    ) throws {
        guard id.count <= Self.maxIDLength else {
            throw ContainerizationError(
                .invalidArgument,
                message: "pod id length \(id.count) exceeds maximum of \(Self.maxIDLength) characters"
            )
        }
        self.id = id
        self.vmm = vmm
        self.hostVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.guestVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.logger = logger

        var config = Configuration()
        try configuration(&config)

        self.config = config
        self.state = AsyncMutex(State(phase: .initialized, containers: [:], pauseProcess: nil))
    }

    private static func createDefaultRuntimeSpec(_ containerID: String, podID: String) -> Spec {
        .init(
            process: .init(),
            hostname: containerID,
            root: .init(
                path: Self.guestRootfsPath(containerID),
                readonly: false
            ),
            linux: .init(
                resources: .init(),
                cgroupsPath: "/container/pod/\(podID)/\(containerID)"
            )
        )
    }

    private func generateRuntimeSpec(containerID: String, config: ContainerConfiguration, rootfs: Mount, writableLayer: Mount? = nil) -> Spec {
        var spec = Self.createDefaultRuntimeSpec(containerID, podID: self.id)

        // Process configuration
        spec.process = config.process.toOCI()

        // Wrap with init process if requested.
        if config.useInit {
            let originalArgs = spec.process?.args ?? []
            spec.process?.args = ["/.cz-init", "--"] + originalArgs
        }

        // General toggles
        // Container-level hostname takes precedence; fall back to pod-level hostname.
        if let hostname = config.hostname ?? self.config.hostname {
            spec.hostname = hostname
        }
        spec.hooks = config.hooks

        // Linux toggles
        spec.linux?.sysctl = config.sysctl
        spec.linux?.maskedPaths = config.maskedPaths
        spec.linux?.readonlyPaths = config.readonlyPaths

        // If the rootfs was requested as read-only, set it in the OCI spec.
        // We let the OCI runtime remount as ro, instead of doing it originally.
        spec.root?.readonly = rootfs.options.contains("ro") && writableLayer == nil

        // Resource limits (if specified)
        if let cpus = config.cpus, cpus > 0 {
            spec.linux?.resources?.cpu = LinuxCPU(
                quota: Int64(cpus * 100_000),
                period: 100_000
            )
        }
        if let memoryInBytes = config.memoryInBytes, memoryInBytes > 0 {
            // The runtime spec's `swap` is the memory and swap total, not the
            // swap alone, so the container's memory limit is folded in here.
            var swapTotal: Int64? = nil
            if let swapInBytes = config.swapInBytes {
                swapTotal = Int64(memoryInBytes + swapInBytes)
            }
            spec.linux?.resources?.memory = LinuxMemory(
                limit: Int64(memoryInBytes),
                swap: swapTotal
            )
        }

        return spec
    }

    static func guestRootfsPath(_ containerID: String) -> String {
        "/run/container/\(containerID)/rootfs"
    }

    static func guestSocketStagingPath(_ socketID: String) -> String {
        "/run/sockets/\(socketID).sock"
    }

    private static func guestVolumePath(_ volumeName: String) -> String {
        "/run/volumes/\(volumeName)"
    }
}

extension LinuxPod {
    /// Number of CPU cores allocated to the pod's VM.
    public var cpus: Int {
        config.cpus
    }

    /// Amount of memory in bytes allocated for the pod's VM.
    public var memoryInBytes: UInt64 {
        config.memoryInBytes
    }

    /// Network interfaces of the pod.
    public var interfaces: [any Interface] {
        config.interfaces
    }

    /// Add a container to the pod.
    ///
    /// When called before `create()`, the container is registered for setup during VM creation.
    /// When called after `create()`, the container is hotplugged into the running VM.
    /// If the underlying VMM does not support hotplug, an error is thrown.
    /// - Parameters:
    ///   - writableLayer: Optional writable layer mount. When provided, an overlayfs is used with
    ///     the container's rootfs as the lower layer and this as the upper layer, so all writes
    ///     go to this layer instead of the rootfs.
    public func addContainer(
        _ id: String,
        rootfs: Mount,
        writableLayer: Mount? = nil,
        configuration: @Sendable @escaping (inout ContainerConfiguration) throws -> Void
    ) async throws {
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
        try await self.state.withLock { state in
            guard state.containers[id] == nil else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "container with id \(id) already exists in pod"
                )
            }

            var config = ContainerConfiguration()
            try configuration(&config)

            // The runtime spec carries memory and swap as one total, so a swap
            // limit cannot be expressed without a memory limit to add it to.
            if config.swapInBytes != nil, config.memoryInBytes == nil {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "container \(id) sets a swap limit without a memory limit"
                )
            }

            let fileMountContext = try FileMountContext.prepare(mounts: config.mounts)

            switch state.phase {
            case .initialized:
                state.containers[id] = PodContainer(
                    id: id,
                    rootfs: rootfs,
                    writableLayer: writableLayer,
                    config: config,
                    state: .registered,
                    process: nil,
                    fileMountContext: fileMountContext
                )

            case .created(let createdState):
                let vm = createdState.vm

                // Strip "ro" as create() does: readonly is expressed through
                // the OCI spec's root.readonly field and a remount in vmexec
                // after setup completes, so the device attaches writable.
                var modifiedRootfs = rootfs
                modifiedRootfs.options.removeAll(where: { $0 == "ro" })

                let attachment = try await vm.hotplug(modifiedRootfs, id: id)

                var updatedFileMountContext = fileMountContext
                do {
                    // The writable layer is a block device like the rootfs,
                    // attached alongside it so the overlay has both layers.
                    var writableAttachment: AttachedFilesystem?
                    if let writableLayer {
                        writableAttachment = try await vm.hotplug(writableLayer, id: id)
                    }

                    let virtioFSMounts = fileMountContext.transformedMounts.filter {
                        if case .virtiofs(_) = $0.runtimeOptions { return true }
                        return false
                    }
                    if !virtioFSMounts.isEmpty {
                        try await vm.hotplugVirtioFS(virtioFSMounts, id: id)
                    }

                    let agent = try await vm.dialAgent()
                    do {
                        if let writableAttachment {
                            try await agent.mountOverlayRootfs(
                                containerID: id,
                                rootfsAttachment: attachment,
                                writableAttachment: writableAttachment,
                                rootfsPath: Self.guestRootfsPath(id)
                            )
                        } else {
                            var mount = attachment.to
                            mount.destination = Self.guestRootfsPath(id)
                            try await agent.mount(mount)
                        }

                        // Shared mounts are handled separately as pod volume
                        // bind mounts; without the filter here, a container
                        // added to an already-created pod would add a
                        // duplicated mount into the shared VM.
                        let nonSharedMounts = fileMountContext.transformedMounts.filter {
                            if case .shared = $0.runtimeOptions { return false }
                            return true
                        }
                        try vm.registerMounts(
                            id: id,
                            rootfs: attachment,
                            writableLayer: writableAttachment,
                            additionalMounts: nonSharedMounts
                        )

                        // Mount this container's additional virtiofs shares in the
                        // guest. create() does this for boot-time containers (the
                        // /run/virtiofs loop); the hotplug path must do the same or
                        // the container's bind mounts from /run/virtiofs/<tag> fail
                        // with ENOENT.
                        //
                        // Derive the new tags from the additional mounts being added;
                        // the machine's storage names what is already shared.
                        let newVirtiofsTags = try virtioFSMounts.map { try hashFilePath(path: $0.source) }
                        if !newVirtiofsTags.isEmpty {
                            try await agent.mkdir(path: "/run/virtiofs", all: true, perms: 0o755)
                            if vm.virtiofsLayout == .perTag {
                                // Tags already mounted in the guest at boot or by a
                                // prior hotplug (i.e. present on another container or
                                // a machine volume).
                                let alreadyMounted: Set<String> = {
                                    var mounted = Set(
                                        vm.storage.containers
                                            .filter { $0.key != id }
                                            .values.flatMap { $0.all }
                                            .filter { $0.type == "virtiofs" }
                                            .map { $0.source })
                                    mounted.formUnion(
                                        vm.storage.volumes.values
                                            .filter { $0.type == "virtiofs" }
                                            .map { $0.source })
                                    return mounted
                                }()
                                var seen: Set<String> = []
                                for tag in newVirtiofsTags
                                where !alreadyMounted.contains(tag) && seen.insert(tag).inserted {
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
                            } else if !state.unifiedVirtiofsMounted && vm.virtiofsLayout == .unified {
                                // Unified layout: one /run/virtiofs mount for the
                                // VM's lifetime, so mount it only if nothing has
                                // mounted it at boot or on an earlier hotplug.
                                try await agent.mount(
                                    ContainerizationOCI.Mount(
                                        type: "virtiofs",
                                        source: "virtiofs",
                                        destination: "/run/virtiofs",
                                        options: []
                                    ))
                                state.unifiedVirtiofsMounted = true
                            }
                        }

                        if fileMountContext.hasFileMounts {
                            let containerMounts = vm.storage.containers[id]?.mounts ?? []
                            try await updatedFileMountContext.mountHoldingDirectories(
                                vmMounts: containerMounts,
                                agent: agent
                            )
                        }

                        if let dns = config.dns ?? self.config.dns {
                            try await agent.configureDNS(
                                config: dns,
                                location: Self.guestRootfsPath(id)
                            )
                        }

                        if let hosts = config.hosts ?? self.config.hosts {
                            try await agent.configureHosts(
                                config: hosts,
                                location: Self.guestRootfsPath(id)
                            )
                        }

                        for socket in config.sockets {
                            try await self.relayUnixSocket(
                                socket: socket,
                                containerID: id,
                                relayManager: createdState.relayManager,
                                agent: agent
                            )
                        }

                        try await agent.close()
                    } catch {
                        try? await agent.umount(path: Self.guestRootfsPath(id), flags: 0)
                        try? await agent.close()
                        throw error
                    }

                    state.containers[id] = PodContainer(
                        id: id,
                        rootfs: rootfs,
                        writableLayer: writableLayer,
                        config: config,
                        state: .created,
                        process: nil,
                        fileMountContext: updatedFileMountContext
                    )
                } catch {
                    try? await vm.releaseHotplug(id: id)
                    try? await vm.releaseVirtioFS(id: id)
                    throw error
                }

            case .errored(let err):
                throw err
            }
        }
    }

    /// Create and start the underlying pod's virtual machine and set up
    /// the runtime environment. All registered containers will have their
    /// rootfs mounted, but no init processes will be running.
    public func create() async throws {
        try await self.state.withLock { state in
            try state.phase.validateForCreate()

            // Build the machine's storage from its containers.
            // Strip "ro" from rootfs options - we handle readonly via the OCI spec's
            // root.readonly field and remount in vmexec after setup is complete.
            // Use transformedMounts from fileMountContext (file mounts become directory shares).
            var machineStorage = MachineMounts()
            for (id, container) in state.containers {
                var modifiedRootfs = container.rootfs
                modifiedRootfs.options.removeAll(where: { $0 == "ro" })
                // Shared mounts are handled separately as pod volume bind mounts.
                let containerMounts = container.fileMountContext.transformedMounts.filter {
                    if case .shared = $0.runtimeOptions { return false }
                    return true
                }
                machineStorage.containers[id] = ContainerMounts(
                    rootfs: modifiedRootfs,
                    writableLayer: container.writableLayer,
                    mounts: containerMounts
                )
            }

            // Validate pod volume names are unique.
            var volumeNames = Set<String>()
            for volume in self.config.volumes {
                guard volumeNames.insert(volume.name).inserted else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "duplicate pod volume name \"\(volume.name)\""
                    )
                }
            }

            // Validate that all shared mounts reference valid pod volume names.
            for (id, container) in state.containers {
                for mount in container.config.mounts {
                    if case .shared = mount.runtimeOptions {
                        guard volumeNames.contains(mount.source) else {
                            throw ContainerizationError(
                                .invalidArgument,
                                message: "container \(id) references unknown pod volume \"\(mount.source)\""
                            )
                        }
                    }
                }
            }
            for volume in self.config.volumes {
                machineStorage.volumes[volume.name] = volume.toMount()
            }
            // The swap area is attached with the machine's own storage so the
            // guest is told the /dev path the VMM allocates it.
            machineStorage.swap = self.config.swapLayer

            // Capture into an immutable `let` so the value is safely usable
            // from the concurrent `withAgent` closure below. The container
            // path makes the same decision in LinuxContainer.create — CH
            // only attaches a virtiofs device when shares are configured,
            // so mounting an unbacked /run/virtiofs would fail with EINVAL
            // on the CH backend.
            let hasVirtiofsMount = machineStorage.ordered.contains { mount in
                if case .virtiofs = mount.runtimeOptions { return true }
                return false
            }

            // The machine carries the guest agent as well as the containers,
            // so it is given the pod's size and the agent's on top; what the
            // pod was given is then what its containers have.
            var vmConfig = VMConfiguration(
                cpus: self.config.cpus + self.config.cpuOverhead,
                memoryInBytes: self.config.memoryInBytes + self.config.memoryOverhead,
                interfaces: self.config.interfaces,
                storage: machineStorage,
                bootLog: self.config.bootLog,
                nestedVirtualization: self.config.virtualization
            )
            vmConfig.extensions = self.config.extensions
            let creationConfig = StandardVMConfig(configuration: vmConfig)
            let vm = try await self.vmm.create(config: creationConfig)
            let relayManager = UnixSocketRelayManager(vm: vm)
            do {
                try await vm.start()
                let containers = state.containers
                let shareProcessNamespace = self.config.shareProcessNamespace
                let pauseProcessHolder = Mutex<LinuxProcess?>(nil)
                let fileMountContextUpdates = Mutex<[String: FileMountContext]>([:])
                let hasSwapLayer = self.config.swapLayer != nil

                try await vm.withAgent { agent in
                    try await agent.standardSetup()

                    // The swap area belongs to the pod rather than to any one
                    // container, so it is enabled once here and every container
                    // reclaims to it through the guest's own memory management.
                    if hasSwapLayer {
                        guard let swap = vm.storage.swap else {
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

                    // Mount the unified virtiofs share at /run/virtiofs only
                    // when at least one container has a virtiofs mount. VZ
                    // tolerates the unbacked mount; CH does not.
                    if hasVirtiofsMount {
                        try await agent.mkdir(path: "/run/virtiofs", all: true, perms: 0o755)
                        if vm.virtiofsLayout == .perTag {
                            // CH backend: one virtio-fs device per source-hash
                            // tag, so mount each tag separately at
                            // /run/virtiofs/<tag>. See LinuxContainer for the
                            // VZ vs. CH model split.
                            var seenTags: Set<String> = []
                            for entry in vm.storage.ordered where entry.type == "virtiofs" {
                                guard seenTags.insert(entry.source).inserted else { continue }
                                let dest = "/run/virtiofs/\(entry.source)"
                                try await agent.mkdir(path: dest, all: true, perms: 0o755)
                                try await agent.mount(
                                    ContainerizationOCI.Mount(
                                        type: "virtiofs",
                                        source: entry.source,
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

                    // Create pause container if PID namespace sharing is enabled
                    if shareProcessNamespace {
                        let pauseID = "pause-\(self.id)"
                        let pauseRootfsPath = "/run/container/\(pauseID)/rootfs"

                        // Bind mount /sbin into the pause container rootfs.
                        // This is where the guest agent lives.
                        try await agent.mount(
                            ContainerizationOCI.Mount(
                                type: "",
                                source: "/sbin",
                                destination: "\(pauseRootfsPath)/sbin",
                                options: ["bind"]
                            ))

                        var pauseSpec = Self.createDefaultRuntimeSpec(pauseID, podID: self.id)
                        pauseSpec.process?.args = ["/sbin/vminitd", "pause"]
                        pauseSpec.hostname = ""
                        pauseSpec.mounts = LinuxContainer.defaultMounts().map {
                            ContainerizationOCI.Mount(
                                type: $0.type,
                                source: $0.source,
                                destination: $0.destination,
                                options: $0.options
                            )
                        }
                        pauseSpec.linux?.namespaces = [
                            LinuxNamespace(type: .cgroup),
                            LinuxNamespace(type: .ipc),
                            LinuxNamespace(type: .mount),
                            LinuxNamespace(type: .pid),
                            LinuxNamespace(type: .uts),
                        ]

                        // Create LinuxProcess for pause container
                        let process = LinuxProcess(
                            pauseID,
                            containerID: pauseID,
                            spec: pauseSpec,
                            io: LinuxProcess.Stdio(stdin: nil, stdout: nil, stderr: nil),
                            ociRuntimePath: nil,
                            agent: agent,
                            vm: vm,
                            logger: self.logger
                        )

                        try await process.start()
                        pauseProcessHolder.withLock { $0 = process }

                        self.logger?.debug("Pause container started", metadata: ["pid": "\(process.pid)"])
                    }

                    // Mount all container rootfs
                    for (_, container) in containers {
                        guard let attached = vm.storage.containers[container.id] else {
                            throw ContainerizationError(.notFound, message: "rootfs mount not found for container \(container.id)")
                        }
                        if let writableAttachment = attached.writableLayer {
                            try await agent.mountOverlayRootfs(
                                containerID: container.id,
                                rootfsAttachment: attached.rootfs,
                                writableAttachment: writableAttachment,
                                rootfsPath: Self.guestRootfsPath(container.id)
                            )
                            continue
                        }
                        var rootfs = attached.rootfs.to
                        rootfs.destination = Self.guestRootfsPath(container.id)
                        try await agent.mount(rootfs)
                    }

                    // Mount file mount holding directories under /run for each container.
                    for (id, container) in containers {
                        if container.fileMountContext.hasFileMounts {
                            var ctx = container.fileMountContext
                            let containerMounts = vm.storage.containers[id]?.mounts ?? []
                            try await ctx.mountHoldingDirectories(
                                vmMounts: containerMounts,
                                agent: agent
                            )
                            fileMountContextUpdates.withLock { $0[id] = ctx }
                        }
                    }

                    // Mount pod-level volumes.
                    for volume in self.config.volumes {
                        guard let attachment = vm.storage.volumes[volume.name] else {
                            throw ContainerizationError(
                                .notFound,
                                message: "attached filesystem not found for pod volume \"\(volume.name)\""
                            )
                        }
                        let guestPath = Self.guestVolumePath(volume.name)
                        try await agent.mount(
                            ContainerizationOCI.Mount(
                                type: volume.format,
                                source: attachment.source,
                                destination: guestPath,
                                options: attachment.options
                            ))
                    }

                    // Start up unix socket relays for each container
                    for (_, container) in containers {
                        for socket in container.config.sockets {
                            try await self.relayUnixSocket(
                                socket: socket,
                                containerID: container.id,
                                relayManager: relayManager,
                                agent: agent
                            )
                        }
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

                    // Setup /etc/resolv.conf and /etc/hosts for each container.
                    // Container-level config takes precedence over pod-level config.
                    for (_, container) in containers {
                        if let dns = container.config.dns ?? self.config.dns {
                            try await agent.configureDNS(
                                config: dns,
                                location: Self.guestRootfsPath(container.id)
                            )
                        }
                        if let hosts = container.config.hosts ?? self.config.hosts {
                            try await agent.configureHosts(
                                config: hosts,
                                location: Self.guestRootfsPath(container.id)
                            )
                        }
                    }
                }

                state.pauseProcess = pauseProcessHolder.withLock { $0 }
                state.unifiedVirtiofsMounted = hasVirtiofsMount && vm.virtiofsLayout == .unified

                // Apply file mount context updates.
                let updates = fileMountContextUpdates.withLock { $0 }
                for (id, ctx) in updates {
                    state.containers[id]?.fileMountContext = ctx
                }

                // Transition all containers to created state
                for id in state.containers.keys {
                    state.containers[id]?.state = .created
                }

                state.phase = .created(.init(vm: vm, relayManager: relayManager))
            } catch {
                try? await relayManager.stopAll()
                try? await vm.stop()
                state.phase.setErrored(error: error)
                throw error
            }
        }
    }

    /// Start a container's initial process.
    public func startContainer(_ containerID: String) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("startContainer")

            guard var container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            guard container.state == .created else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be in created state to start"
                )
            }

            let agent = try await createdState.vm.dialAgent()
            do {
                var spec = self.generateRuntimeSpec(containerID: containerID, config: container.config, rootfs: container.rootfs, writableLayer: container.writableLayer)
                // We don't need the rootfs, nor do OCI runtimes want it included.
                // Also filter out file mount holding directories - we mount those separately under /run.
                // Transform virtiofs mounts to bind mounts from /run/virtiofs/{tag}
                let containerMounts = createdState.vm.storage.containers[containerID]?.mounts ?? []
                let holdingTags = container.fileMountContext.holdingDirectoryTags
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
                    + container.fileMountContext.ociBindMounts()

                // When useInit is enabled, bind mount vminitd from the VM's filesystem
                // into the container so it can be executed.
                if container.config.useInit {
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
                for socket in container.config.sockets where socket.direction == .into {
                    mounts.append(
                        ContainerizationOCI.Mount(
                            type: "bind",
                            source: Self.guestSocketStagingPath(socket.id),
                            destination: socket.destination.path,
                            options: ["bind"]
                        ))
                }

                // Bind mount pod volumes into the container.
                for mount in container.config.mounts {
                    if case .shared = mount.runtimeOptions {
                        mounts.append(
                            ContainerizationOCI.Mount(
                                type: "none",
                                source: Self.guestVolumePath(mount.source),
                                destination: mount.destination,
                                options: ["bind"] + mount.options
                            ))
                    }
                }

                spec.mounts = cleanAndSortMounts(mounts)

                // Configure namespaces for the container
                var namespaces: [LinuxNamespace] = [
                    LinuxNamespace(type: .cgroup),
                    LinuxNamespace(type: .ipc),
                    LinuxNamespace(type: .mount),
                    LinuxNamespace(type: .uts),
                ]

                // Either join pause container's pid ns or create a new one
                if self.config.shareProcessNamespace, let pausePID = state.pauseProcess?.pid {
                    let nsPath = "/proc/\(pausePID)/ns/pid"

                    self.logger?.debug(
                        "Container joining pause PID namespace",
                        metadata: [
                            "container": "\(containerID)",
                            "pausePID": "\(pausePID)",
                            "nsPath": "\(nsPath)",
                        ])

                    namespaces.append(LinuxNamespace(type: .pid, path: nsPath))
                } else {
                    namespaces.append(LinuxNamespace(type: .pid))
                }

                spec.linux?.namespaces = namespaces

                let stdio = IOUtil.setup(
                    portAllocator: self.hostVsockPorts,
                    stdin: container.config.process.stdin,
                    stdout: container.config.process.stdout,
                    stderr: container.config.process.stderr
                )

                let process = LinuxProcess(
                    containerID,
                    containerID: containerID,
                    spec: spec,
                    io: stdio,
                    ociRuntimePath: container.config.ociRuntimePath,
                    agent: agent,
                    vm: createdState.vm,
                    logger: self.logger
                )
                try await process.start()

                container.process = process
                container.state = .started
                state.containers[containerID] = container
            } catch {
                try? await agent.close()
                throw error
            }
        }
    }

    /// Stop a container from executing.
    public func stopContainer(_ containerID: String) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("stopContainer")

            guard var container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            // Allow stop to be called multiple times
            if container.state == .stopped {
                return
            }

            // Handle containers that were hotplugged but never started
            if container.state == .created {
                // Release the hotplug device and virtiofs shares
                try? await createdState.vm.releaseHotplug(id: containerID)
                try? await createdState.vm.releaseVirtioFS(id: containerID)

                container.state = .stopped
                state.containers[containerID] = container
                return
            }

            guard container.state == .started, let process = container.process else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be in started state to stop"
                )
            }

            do {
                // Check if the vm is even still running
                if createdState.vm.state == .stopped {
                    container.state = .stopped
                    state.containers[containerID] = container
                    return
                }

                try await process.kill(.kill)
                try await process.wait(timeoutInSeconds: 3)

                let hasWritableLayer = container.writableLayer != nil
                try await createdState.vm.withAgent { agent in
                    // Unmount the rootfs
                    try await agent.umount(
                        path: Self.guestRootfsPath(containerID),
                        flags: 0
                    )

                    // If we have a writable layer, we also need to unmount the lower and upper layers.
                    if hasWritableLayer {
                        let upperPath = "/run/container/\(containerID)/upper"
                        let lowerPath = "/run/container/\(containerID)/lower"
                        try await agent.umount(path: upperPath, flags: 0)
                        try await agent.umount(path: lowerPath, flags: 0)
                    }
                }

                // Release the hotplug device and virtiofs shares so they can be reused by new containers
                try await createdState.vm.releaseHotplug(id: containerID)
                try await createdState.vm.releaseVirtioFS(id: containerID)

                // Clean up the process resources
                try await process.delete()

                container.process = nil
                container.state = .stopped
                state.containers[containerID] = container
            } catch {
                // Try to release the hotplug device and virtiofs shares even on error
                try? await createdState.vm.releaseHotplug(id: containerID)
                try? await createdState.vm.releaseVirtioFS(id: containerID)

                container.state = .errored
                container.process = nil
                state.containers[containerID] = container

                throw error
            }
        }
    }

    /// Take a container out of the pod, so its name is free to place again.
    ///
    /// Stopping a container tears down what it was running and keeps its
    /// place; the name still answers for it, and placing another container
    /// under it is refused. Removal is the separate act the runtime
    /// specification names for giving the place up, taken once the container
    /// has stopped. A container that is running keeps its place and this
    /// call refuses it.
    /// https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
    public func removeContainer(_ containerID: String) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }
            switch container.state {
            case .registered, .stopped, .errored:
                state.containers[containerID] = nil
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must stop before it is removed"
                )
            }
        }
    }

    /// Stop the pod's VM and all containers.
    public func stop() async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("stop")

            do {
                try await createdState.relayManager.stopAll()

                // Stop all containers
                let containerIDs = Array(state.containers.keys)

                for containerID in containerIDs {
                    // Stop the container inline
                    guard var container = state.containers[containerID] else {
                        continue
                    }

                    if container.state == .stopped {
                        continue
                    }

                    if let process = container.process, container.state == .started {
                        if createdState.vm.state != .stopped {
                            try? await process.kill(.kill)
                            _ = try? await process.wait(timeoutInSeconds: 3)

                            try? await createdState.vm.withAgent { agent in
                                try await agent.umount(
                                    path: Self.guestRootfsPath(containerID),
                                    flags: 0
                                )
                            }
                        }

                        try? await process.delete()
                        container.process = nil
                        container.state = .stopped

                        state.containers[containerID] = container
                    }
                }

                // Unmount pod-level volumes.
                if createdState.vm.state != .stopped && !self.config.volumes.isEmpty {
                    try? await createdState.vm.withAgent { agent in
                        for volume in self.config.volumes {
                            try? await agent.umount(
                                path: Self.guestVolumePath(volume.name),
                                flags: 0
                            )
                        }
                    }
                }

                try await createdState.vm.stop()
                state.phase = .initialized
            } catch {
                try? await createdState.vm.stop()
                state.phase.setErrored(error: error)
                throw error
            }
        }
    }

    /// Send a signal to a container.
    public func killContainer(_ containerID: String, signal: Signal) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            try await process.kill(signal)
        }
    }

    /// Wait for a container to exit. Returns the exit code.
    @discardableResult
    public func waitContainer(_ containerID: String, timeoutInSeconds: Int64? = nil) async throws -> ExitStatus {
        let process = try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            return process
        }
        return try await process.wait(timeoutInSeconds: timeoutInSeconds)
    }

    /// Resize a container's terminal (if one was requested).
    public func resizeContainer(_ containerID: String, to: Terminal.Size) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            try await process.resize(to: to)
        }
    }

    /// Execute a new process in a container.
    public func execInContainer(
        _ containerID: String,
        processID: String,
        configuration: @Sendable @escaping (inout LinuxProcessConfiguration) throws -> Void
    ) async throws -> LinuxProcess {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("execInContainer")

            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            guard container.state == .started else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started to exec"
                )
            }

            var spec = self.generateRuntimeSpec(containerID: containerID, config: container.config, rootfs: container.rootfs, writableLayer: container.writableLayer)
            // Inherit environment variables, working directory, user, capabilities, rlimits from container process.
            // Reset: process arguments, terminal, stdio as these are not supposed to be inherited.
            var config = container.config.process
            config.arguments = []
            config.terminal = false
            config.stdin = nil
            config.stdout = nil
            config.stderr = nil
            try configuration(&config)
            spec.process = config.toOCI()

            let stdio = IOUtil.setup(
                portAllocator: self.hostVsockPorts,
                stdin: config.stdin,
                stdout: config.stdout,
                stderr: config.stderr
            )
            let agent = try await createdState.vm.dialAgent()
            let process = LinuxProcess(
                processID,
                containerID: containerID,
                spec: spec,
                io: stdio,
                ociRuntimePath: container.config.ociRuntimePath,
                agent: agent,
                vm: createdState.vm,
                logger: self.logger
            )
            return process
        }
    }

    /// List all container IDs in the pod.
    public func listContainers() async -> [String] {
        await self.state.withLock { state in
            Array(state.containers.keys)
        }
    }

    /// Get statistics for containers in the pod.
    public func statistics(containerIDs: [String]? = nil, categories: StatCategory = .all) async throws -> [ContainerStatistics] {
        let (createdState, ids) = try await self.state.withLock { state in
            let createdState = try state.phase.createdState("statistics")
            let ids = containerIDs ?? Array(state.containers.keys)
            return (createdState, ids)
        }

        let stats = try await createdState.vm.withAgent { agent in
            try await agent.containerStatistics(containerIDs: ids, categories: categories)
        }

        return stats
    }

    /// Dial a vsock port in the pod's VM.
    public func dialVsock(port: UInt32) async throws -> FileHandle {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("dialVsock")
            return try await createdState.vm.dial(port)
        }
    }

    /// Provides scoped access to the underlying virtual machine instance.
    ///
    /// Most users should prefer the higher level APIs on ``LinuxPod``
    /// directly. This is intended for advanced use cases that need to interact
    /// with the virtual machine outside of the pod abstraction.
    public func withVirtualMachineInstance<T: Sendable>(
        _ fn: @Sendable (any VirtualMachineInstance) async throws -> T
    ) async throws -> T {
        let vm = try await self.state.withLock { state in
            try state.phase.createdState("withVirtualMachineInstance").vm
        }
        return try await fn(vm)
    }

    // Perform filesystem operations in a container.
    public func filesystemOperation(_ containerID: String, operation: FilesystemOperation, path: String) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("filesystemOperation")

            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            guard container.state == .started else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started to perform filesystem operations"
                )
            }

            try await createdState.vm.withAgent { agent in
                guard let vminitd = agent as? Vminitd else {
                    throw ContainerizationError(.unsupported, message: "filesystemOperation requires Vminitd agent")
                }
                let guestPath = URL(filePath: Self.guestRootfsPath(containerID)).appending(path: path).path
                try await vminitd.filesystemOperation(operation: operation, path: guestPath)
            }
        }
    }

    /// Default chunk size for file transfers (1MiB).
    public static let defaultCopyChunkSize = GuestFileTransfer.defaultChunkSize

    /// Copy a file or directory from the host into a container in the pod.
    ///
    /// Data transfer happens over a dedicated vsock connection. For
    /// directories, the source is archived as tar+gzip and streamed directly
    /// through vsock without intermediate temp files.
    public func copyIn(
        _ containerID: String,
        from source: URL,
        to destination: URL,
        mode: UInt32 = 0o644,
        createParents: Bool = true,
        chunkSize: Int = defaultCopyChunkSize
    ) async throws {
        try await self.state.withLock { state in
            try await self.transfer(containerID, state: state, operation: "copyIn").copyIn(
                from: source,
                to: destination,
                mode: mode,
                createParents: createParents,
                chunkSize: chunkSize
            )
        }
    }

    /// Copy a file or directory from a container in the pod to the host.
    ///
    /// Data transfer happens over a dedicated vsock connection. For
    /// directories, the guest archives the source as tar+gzip and streams it
    /// directly through vsock. The host extracts the archive without
    /// intermediate temp files.
    public func copyOut(
        _ containerID: String,
        from source: URL,
        to destination: URL,
        createParents: Bool = true,
        chunkSize: Int = defaultCopyChunkSize
    ) async throws {
        try await self.state.withLock { state in
            try await self.transfer(containerID, state: state, operation: "copyOut").copyOut(
                from: source,
                to: destination,
                createParents: createParents,
                chunkSize: chunkSize
            )
        }
    }

    /// A transfer against one container's filesystem, on a port of its own.
    private func transfer(_ containerID: String, state: State, operation: String) throws -> GuestFileTransfer {
        let createdState = try state.phase.createdState(operation)

        guard let container = state.containers[containerID] else {
            throw ContainerizationError(
                .notFound,
                message: "container \(containerID) not found in pod"
            )
        }

        guard container.state == .started else {
            throw ContainerizationError(
                .invalidState,
                message: "container \(containerID) must be started to copy files"
            )
        }

        return GuestFileTransfer(
            vm: createdState.vm,
            guestRoot: Self.guestRootfsPath(containerID),
            port: self.hostVsockPorts.wrappingAdd(1, ordering: .relaxed).oldValue,
            queue: self.copyQueue
        )
    }

    /// Close a container's standard input to signal no more input is arriving.
    public func closeContainerStdin(_ containerID: String) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            try await process.closeStdin()
        }
    }

    /// Relay a unix socket for a container.
    public func relayUnixSocket(_ containerID: String, socket: UnixSocketConfiguration) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("relayUnixSocket")

            guard let _ = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            try await createdState.vm.withAgent { agent in
                try await self.relayUnixSocket(
                    socket: socket,
                    containerID: containerID,
                    relayManager: createdState.relayManager,
                    agent: agent
                )
            }
        }
    }

    private func relayUnixSocket(
        socket: UnixSocketConfiguration,
        containerID: String,
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

        // Adjust paths to be relative to the container's rootfs
        let rootInGuest = URL(filePath: Self.guestRootfsPath(containerID))

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
}
