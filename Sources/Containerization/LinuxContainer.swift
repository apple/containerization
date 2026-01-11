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

/// `LinuxContainer` is an easy to use type for launching and managing the
/// full lifecycle of a Linux container ran inside of a virtual machine.
public final class LinuxContainer: Container, Sendable {
    /// The identifier of the container.
    public let id: String

    /// Rootfs for the container.
    public let rootfs: Mount

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
        public var hostname: String = ""
        /// The system control options for the container.
        public var sysctl: [String: String] = [:]
        /// The network interfaces for the container.
        public var interfaces: [any Interface] = []
        /// The Unix domain socket relays to setup for the container.
        public var sockets: [UnixSocketConfiguration] = []
        /// The mounts for the container.
        public var mounts: [Mount] = LinuxContainer.defaultMounts()
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

        public init() {}

        public init(
            process: LinuxProcessConfiguration,
            cpus: Int = 4,
            memoryInBytes: UInt64 = 1024.mib(),
            hostname: String = "",
            sysctl: [String: String] = [:],
            interfaces: [any Interface] = [],
            sockets: [UnixSocketConfiguration] = [],
            mounts: [Mount] = LinuxContainer.defaultMounts(),
            dns: DNS? = nil,
            hosts: Hosts? = nil,
            virtualization: Bool = false,
            bootLog: BootLog? = nil,
            ociRuntimePath: String? = nil
        ) {
            self.process = process
            self.cpus = cpus
            self.memoryInBytes = memoryInBytes
            self.hostname = hostname
            self.sysctl = sysctl
            self.interfaces = interfaces
            self.sockets = sockets
            self.mounts = mounts
            self.dns = dns
            self.hosts = hosts
            self.virtualization = virtualization
            self.bootLog = bootLog
            self.ociRuntimePath = ociRuntimePath
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
        }

        struct StartedState: Sendable {
            let vm: any VirtualMachineInstance
            let process: LinuxProcess
            let relayManager: UnixSocketRelayManager
            var vendedProcesses: [String: LinuxProcess]

            init(_ state: CreatedState, process: LinuxProcess) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = process
                self.vendedProcesses = [:]
            }

            init(_ state: PausedState) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = state.process
                self.vendedProcesses = state.vendedProcesses
            }
        }

        struct PausedState: Sendable {
            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager
            let process: LinuxProcess
            var vendedProcesses: [String: LinuxProcess]

            init(_ state: StartedState) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = state.process
                self.vendedProcesses = state.vendedProcesses
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
    }

    private let vmm: VirtualMachineManager
    private let logger: Logger?

    /// Create a new `LinuxContainer`.
    ///
    /// - Parameters:
    ///   - id: The identifier for the container.
    ///   - rootfs: The root filesystem mount containing the container image contents.
    ///   - vmm: The virtual machine manager that will handle launching the VM for the container.
    ///   - logger: Optional logger for container operations.
    ///   - configuration: A closure that configures the container by modifying the Configuration instance.
    public convenience init(
        _ id: String,
        rootfs: Mount,
        vmm: VirtualMachineManager,
        logger: Logger? = nil,
        configuration: (inout Configuration) throws -> Void
    ) throws {
        var config = Configuration()
        try configuration(&config)
        self.init(
            id,
            rootfs: rootfs,
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
    ///   - vmm: The virtual machine manager that will handle launching the VM for the container.
    ///   - configuration: The container configuration specifying process, resources, networking, and other settings.
    ///   - logger: Optional logger for container operations.
    public init(
        _ id: String,
        rootfs: Mount,
        vmm: VirtualMachineManager,
        configuration: LinuxContainer.Configuration,
        logger: Logger? = nil
    ) {
        self.id = id
        self.vmm = vmm
        self.hostVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.guestVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.logger = logger
        self.config = configuration
        self.state = AsyncMutex(.initialized)
        self.rootfs = rootfs
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

        // General toggles.
        spec.hostname = config.hostname

        // Linux toggles.
        spec.linux?.sysctl = config.sysctl

        // If the rootfs was requested as read-only, set it in the OCI spec.
        // We let the OCI runtime remount as ro, instead of doing it originally.
        spec.root?.readonly = self.rootfs.options.contains("ro")

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

            let vmConfig = VMConfiguration(
                cpus: self.cpus,
                memoryInBytes: self.memoryInBytes,
                interfaces: self.interfaces,
                mountsByID: [self.id: [modifiedRootfs] + self.config.mounts],
                bootLog: self.config.bootLog,
                nestedVirtualization: self.config.virtualization
            )
            let creationConfig = StandardVMConfig(configuration: vmConfig)
            let vm = try await self.vmm.create(config: creationConfig)
            let relayManager = UnixSocketRelayManager(vm: vm, log: self.logger)

            try await vm.start()
            do {
                try await vm.withAgent { agent in
                    try await agent.standardSetup()

                    // Mount the rootfs.
                    guard let attachments = vm.mounts[self.id], let rootfsAttachment = attachments.first else {
                        throw ContainerizationError(.notFound, message: "rootfs mount not found")
                    }
                    var rootfs = rootfsAttachment.to
                    rootfs.destination = Self.guestRootfsPath(self.id)
                    try await agent.mount(rootfs)

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
                    // 3. If a gateway IP address is present, add the default route.
                    for (index, i) in self.interfaces.enumerated() {
                        let name = "eth\(index)"
                        try await agent.addressAdd(name: name, ipv4Address: i.ipv4Address)
                        try await agent.up(name: name, mtu: 1280)
                        if let ipv4Gateway = i.ipv4Gateway {
                            try await agent.routeAddDefault(name: name, ipv4Gateway: ipv4Gateway)
                        }
                    }

                    // Setup /etc/resolv.conf and /etc/hosts if asked for.
                    if let dns = self.config.dns {
                        try await agent.configureDNS(config: dns, location: rootfs.destination)
                    }
                    if let hosts = self.config.hosts {
                        try await agent.configureHosts(config: hosts, location: rootfs.destination)
                    }

                }
                state = .created(.init(vm: vm, relayManager: relayManager))
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
                // We don't need the rootfs, nor do OCI runtimes want it included.
                let containerMounts = createdState.vm.mounts[self.id] ?? []
                spec.mounts = containerMounts.dropFirst().map { $0.to }

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

    private static func setupIO(
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

    /// Stop the container from executing. This MUST be called even if wait() has returned
    /// as their are additional resources to free.
    public func stop() async throws {
        try await self.state.withLock { state in
            // Allow stop to be called multiple times.
            if case .stopped = state {
                return
            }

            let startedState = try state.startedState("stop")
            let vm = startedState.vm

            var firstError: Error?
            do {
                try await startedState.relayManager.stopAll()
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

                    // Now lets ensure every process is donezo.
                    try await agent.kill(pid: -1, signal: SIGKILL)

                    // Wait on init proc exit. Give it 5 seconds of leeway.
                    _ = try await agent.waitProcess(
                        id: self.id,
                        containerID: self.id,
                        timeoutInSeconds: 5
                    )

                    // Today, we leave EBUSY looping and other fun logic up to the
                    // guest agent.
                    try await agent.umount(
                        path: Self.guestRootfsPath(self.id),
                        flags: 0
                    )

                    try await agent.sync()
                }
            } catch {
                self.logger?.error("failed during guest cleanup: \(error)")
                firstError = firstError ?? error
            }

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
    public func kill(_ signal: Int32) async throws {
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
                onDelete: { [weak self] in
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
                onDelete: { [weak self] in
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
    public func statistics() async throws -> ContainerStatistics {
        try await self.state.withLock {
            let state = try $0.startedState("statistics")

            let stats = try await state.vm.withAgent { agent in
                let allStats = try await agent.containerStatistics(containerIDs: [self.id])
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

    /// Relay a unix socket from in the container to the host, or from the host
    /// to inside the container.
    public func relayUnixSocket(socket: UnixSocketConfiguration) async throws {
        try await self.state.withLock {
            let state = try $0.startedState("relayUnixSocket")

            try await state.vm.withAgent { agent in
                try await self.relayUnixSocket(
                    socket: socket,
                    relayManager: state.relayManager,
                    agent: agent
                )
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
            socket.destination = rootInGuest.appending(path: socket.destination.path)
        } else {
            port = self.guestVsockPorts.wrappingAdd(1, ordering: .relaxed).oldValue
            socket.source = rootInGuest.appending(path: socket.source.path)
        }

        try await relayManager.start(port: port, socket: socket)
        try await relayAgent.relaySocket(port: port, configuration: socket)
    }

    /// Default chunk size for file transfers (1MiB).
    public static let defaultCopyChunkSize = 1024 * 1024

    /// Copy a file from the host into the container.
    public func copyIn(
        from source: URL,
        to destination: URL,
        mode: UInt32 = 0o644,
        createParents: Bool = true,
        chunkSize: Int = defaultCopyChunkSize,
        progress: ProgressHandler? = nil
    ) async throws {
        try await self.state.withLock {
            let state = try $0.startedState("copyIn")

            let guestPath = URL(filePath: self.root).appending(path: destination.path)
            try await state.vm.withAgent { agent in
                try await agent.copyIn(
                    from: source,
                    to: guestPath,
                    mode: mode,
                    createParents: createParents,
                    chunkSize: chunkSize,
                    progress: progress
                )
            }
        }
    }

    /// Copy a file from the container to the host.
    public func copyOut(
        from source: URL,
        to destination: URL,
        createParents: Bool = true,
        chunkSize: Int = defaultCopyChunkSize,
        progress: ProgressHandler? = nil
    ) async throws {
        try await self.state.withLock {
            let state = try $0.startedState("copyOut")

            let guestPath = URL(filePath: self.root).appending(path: source.path)
            try await state.vm.withAgent { agent in
                try await agent.copyOut(
                    from: guestPath,
                    to: destination,
                    createParents: createParents,
                    chunkSize: chunkSize,
                    progress: progress
                )
            }
        }
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

#endif
