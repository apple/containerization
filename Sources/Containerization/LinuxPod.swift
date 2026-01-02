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

#if os(macOS)
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import Synchronization

import struct ContainerizationOS.Terminal

/// NOTE: Experimental API
///
/// `LinuxPod` allows managing multiple Linux containers within a single
/// virtual machine. Each container has its own rootfs and process, but
/// shares the VM's resources (CPU, memory, network).
public final class LinuxPod: Sendable {
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
        /// The network interfaces for the pod.
        public var interfaces: [any Interface] = []
        /// The DNS configuration for the pod.
        public var dns: DNS?
        /// Whether nested virtualization should be turned on for the pod.
        public var virtualization: Bool = false
        /// Optional file path to store serial boot logs.
        public var bootLog: BootLog?
        /// Whether containers in the pod should share a PID namespace.
        /// When enabled, all containers can see each other's processes.
        public var shareProcessNamespace: Bool = false

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
        /// The hostname for the container.
        public var hostname: String = ""
        /// The system control options for the container.
        public var sysctl: [String: String] = [:]
        /// The mounts for the container.
        public var mounts: [Mount] = LinuxContainer.defaultMounts()
        /// The Unix domain socket relays to setup for the container.
        public var sockets: [UnixSocketConfiguration] = []

        public init() {}
    }

    private struct PodContainer: Sendable {
        let id: String
        let rootfs: Mount
        let config: ContainerConfiguration
        var state: ContainerState
        var process: LinuxProcess?

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

    private struct State: Sendable {
        var phase: Phase
        var containers: [String: PodContainer]
        var pauseProcess: LinuxProcess?
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

    private func generateRuntimeSpec(containerID: String, config: ContainerConfiguration, rootfs: Mount) -> Spec {
        var spec = Self.createDefaultRuntimeSpec(containerID, podID: self.id)

        // Process configuration
        spec.process = config.process.toOCI()

        // General toggles
        spec.hostname = config.hostname

        // Linux toggles
        spec.linux?.sysctl = config.sysctl

        // If the rootfs was requested as read-only, set it in the OCI spec.
        // We let the OCI runtime remount as ro, instead of doing it originally.
        spec.root?.readonly = rootfs.options.contains("ro")

        // Resource limits (if specified)
        if let cpus = config.cpus, cpus > 0 {
            spec.linux?.resources?.cpu = LinuxCPU(
                quota: Int64(cpus * 100_000),
                period: 100_000
            )
        }
        if let memoryInBytes = config.memoryInBytes, memoryInBytes > 0 {
            spec.linux?.resources?.memory = LinuxMemory(
                limit: Int64(memoryInBytes)
            )
        }

        return spec
    }

    private static func guestRootfsPath(_ containerID: String) -> String {
        "/run/container/\(containerID)/rootfs"
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

    /// Add a container to the pod. This must be called before `create()`.
    /// The container will be registered but not started.
    public func addContainer(
        _ id: String,
        rootfs: Mount,
        configuration: @Sendable @escaping (inout ContainerConfiguration) throws -> Void
    ) async throws {
        try await self.state.withLock { state in
            guard case .initialized = state.phase else {
                throw ContainerizationError(
                    .invalidState,
                    message: "pod must be initialized to add container"
                )
            }

            guard state.containers[id] == nil else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "container with id \(id) already exists in pod"
                )
            }

            var config = ContainerConfiguration()
            try configuration(&config)

            state.containers[id] = PodContainer(
                id: id,
                rootfs: rootfs,
                config: config,
                state: .registered,
                process: nil
            )
        }
    }

    /// Create and start the underlying pod's virtual machine and set up
    /// the runtime environment. All registered containers will have their
    /// rootfs mounted, but no init processes will be running.
    public func create() async throws {
        try await self.state.withLock { state in
            try state.phase.validateForCreate()

            // Build mountsByID for all containers.
            // Strip "ro" from rootfs options - we handle readonly via the OCI spec's
            // root.readonly field and remount in vmexec after setup is complete.
            var mountsByID: [String: [Mount]] = [:]
            for (id, container) in state.containers {
                var modifiedRootfs = container.rootfs
                modifiedRootfs.options.removeAll(where: { $0 == "ro" })
                mountsByID[id] = [modifiedRootfs] + container.config.mounts
            }

            let vmConfig = VMConfiguration(
                cpus: self.config.cpus,
                memoryInBytes: self.config.memoryInBytes,
                interfaces: self.config.interfaces,
                mountsByID: mountsByID,
                bootLog: self.config.bootLog,
                nestedVirtualization: self.config.virtualization
            )
            let creationConfig = StandardVMConfig(configuration: vmConfig)
            let vm = try await self.vmm.create(config: creationConfig)
            let relayManager = UnixSocketRelayManager(vm: vm)
            try await vm.start()

            do {
                let containers = state.containers
                let shareProcessNamespace = self.config.shareProcessNamespace
                let pauseProcessHolder = Mutex<LinuxProcess?>(nil)

                try await vm.withAgent { agent in
                    try await agent.standardSetup()

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
                        guard let attachments = vm.mounts[container.id], let rootfsAttachment = attachments.first else {
                            throw ContainerizationError(.notFound, message: "rootfs mount not found for container \(container.id)")
                        }
                        var rootfs = rootfsAttachment.to
                        rootfs.destination = Self.guestRootfsPath(container.id)
                        try await agent.mount(rootfs)
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
                    // 3. If a gateway IP address is present, add the default route.
                    for (index, i) in self.interfaces.enumerated() {
                        let name = "eth\(index)"
                        try await agent.addressAdd(name: name, ipv4Address: i.ipv4Address)
                        try await agent.up(name: name, mtu: 1280)
                        if let ipv4Gateway = i.ipv4Gateway {
                            try await agent.routeAddDefault(name: name, ipv4Gateway: ipv4Gateway)
                        }
                    }

                    // Setup /etc/resolv.conf if asked for
                    if let dns = self.config.dns {
                        // Configure DNS in each container's rootfs
                        for (_, container) in containers {
                            try await agent.configureDNS(
                                config: dns,
                                location: Self.guestRootfsPath(container.id)
                            )
                        }
                    }
                }

                state.pauseProcess = pauseProcessHolder.withLock { $0 }

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
                var spec = self.generateRuntimeSpec(containerID: containerID, config: container.config, rootfs: container.rootfs)
                // We don't need the rootfs, nor do OCI runtimes want it included.
                let containerMounts = createdState.vm.mounts[containerID] ?? []
                spec.mounts = containerMounts.dropFirst().map { $0.to }

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
                    ociRuntimePath: nil,
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

                try await process.kill(SIGKILL)
                try await process.wait(timeoutInSeconds: 3)

                try await createdState.vm.withAgent { agent in
                    // Unmount the rootfs
                    try await agent.umount(
                        path: Self.guestRootfsPath(containerID),
                        flags: 0
                    )
                }

                // Clean up the process resources
                try await process.delete()

                container.process = nil
                container.state = .stopped
                state.containers[containerID] = container
            } catch {
                container.state = .errored
                container.process = nil
                state.containers[containerID] = container

                throw error
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
                            try? await process.kill(SIGKILL)
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
    public func killContainer(_ containerID: String, signal: Int32) async throws {
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

            var spec = self.generateRuntimeSpec(containerID: containerID, config: container.config, rootfs: container.rootfs)
            var config = LinuxProcessConfiguration()
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
                ociRuntimePath: nil,
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
    public func statistics(containerIDs: [String]? = nil) async throws -> [ContainerStatistics] {
        let (createdState, ids) = try await self.state.withLock { state in
            let createdState = try state.phase.createdState("statistics")
            let ids = containerIDs ?? Array(state.containers.keys)
            return (createdState, ids)
        }

        let stats = try await createdState.vm.withAgent { agent in
            try await agent.containerStatistics(containerIDs: ids)
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
            socket.destination = rootInGuest.appending(path: socket.destination.path)
        } else {
            port = self.guestVsockPorts.wrappingAdd(1, ordering: .relaxed).oldValue
            socket.source = rootInGuest.appending(path: socket.source.path)
        }

        try await relayManager.start(port: port, socket: socket)
        try await relayAgent.relaySocket(port: port, configuration: socket)
    }
}

#endif
