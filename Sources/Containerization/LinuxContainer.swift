//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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
        public var process = LinuxProcessConfiguration.init()
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
        /// Whether rosetta x86-64 emulation should be setup for the container.
        public var rosetta: Bool = false
        /// Whether nested virtualization should be turned on for the container.
        public var virtualization: Bool = false
        /// The mounts for the container.
        public var mounts: [Mount] = LinuxContainer.defaultMounts()
        /// The DNS configuration for the container.
        public var dns: DNS?
        /// The hosts to add to /etc/hosts for the container.
        public var hosts: Hosts?

        public init() {}
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

            init(_ state: CreatedState, process: LinuxProcess) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = process
            }

            init(_ state: PausedState) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = state.process
            }
        }

        struct PausedState: Sendable {
            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager
            let process: LinuxProcess

            init(_ state: StartedState) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = state.process
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

    /// Create a new `LinuxContainer`. A `Mount` that contains the contents
    /// of the container image must be provided, as well as a `VirtualMachineManager`
    /// instance that will handle launching the virtual machine the container will
    /// execute inside of.
    public init(
        _ id: String,
        rootfs: Mount,
        vmm: VirtualMachineManager,
        logger: Logger? = nil,
        configuration: (inout Configuration) throws -> Void
    ) throws {
        self.id = id
        self.vmm = vmm
        self.hostVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.guestVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.rootfs = rootfs
        self.logger = logger

        var config = Configuration()
        try configuration(&config)

        self.config = config
        self.state = AsyncMutex(.initialized)
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

        return spec
    }

    public static func defaultMounts() -> [Mount] {
        let defaultOptions = ["nosuid", "noexec", "nodev"]
        return [
            .any(type: "proc", source: "proc", destination: "/proc", options: defaultOptions),
            .any(type: "sysfs", source: "sysfs", destination: "/sys", options: defaultOptions),
            .any(type: "devtmpfs", source: "none", destination: "/dev", options: ["nosuid", "mode=755"]),
            .any(type: "mqueue", source: "mqueue", destination: "/dev/mqueue", options: defaultOptions),
            .any(type: "tmpfs", source: "tmpfs", destination: "/dev/shm", options: defaultOptions + ["mode=1777", "size=65536k"]),
            .any(type: "cgroup2", source: "none", destination: "/sys/fs/cgroup", options: defaultOptions),
            .any(type: "devpts", source: "devpts", destination: "/dev/pts", options: ["nosuid", "noexec", "gid=5", "mode=620", "ptmxmode=666"]),
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

            let vm = try self.vmm.create(container: self)
            try await vm.start()
            do {
                let relayManager = UnixSocketRelayManager(vm: vm)
                try await vm.withAgent { agent in
                    try await agent.standardSetup()

                    // Mount the rootfs.
                    var rootfs = vm.mounts[0].to
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
                        try await agent.addressAdd(name: name, address: i.address)
                        try await agent.up(name: name, mtu: 1280)
                        if let gateway = i.gateway {
                            try await agent.routeAddDefault(name: name, gateway: gateway)
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
                spec.mounts = createdState.vm.mounts.dropFirst().map { $0.to }

                let stdio = Self.setupIO(
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

            do {
                try await startedState.relayManager.stopAll()

                // It's possible the state of the vm is not in a great spot
                // if the guest panicked or had any sort of bug/fault.
                // First check if the vm is even still running, as trying to
                // use a vsock handle like below here will cause NIO to
                // fatalError because we'll get an EBADF.
                if startedState.vm.state == .stopped {
                    state = .stopped
                    return
                }

                try await startedState.vm.withAgent { agent in
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
                }

                // Lets free up the init procs resources, as this includes the open agent conn.
                try? await startedState.process.delete()

                try await startedState.vm.stop()
                state = .stopped
            } catch {
                state.setErrored(error: error)
                throw error
            }
        }
    }

    /// Pause the container.
    public func pause() async throws {
        try await self.state.withLock { state in
            let startedState = try state.startedState("pause")
            try await startedState.vm.pause()
            state = .paused(.init(startedState))
        }
    }

    /// Resume the container.
    public func resume() async throws {
        try await self.state.withLock { state in
            let pausedState = try state.pausedState("resume")
            try await pausedState.vm.resume()
            state = .started(.init(pausedState))
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
        try await self.state.withLock {
            let state = try $0.startedState("exec")

            var spec = self.generateRuntimeSpec()
            var config = LinuxProcessConfiguration()
            try configuration(&config)
            spec.process = config.toOCI()

            let stdio = Self.setupIO(
                portAllocator: self.hostVsockPorts,
                stdin: config.stdin,
                stdout: config.stdout,
                stderr: config.stderr
            )
            let agent = try await state.vm.dialAgent()
            let process = LinuxProcess(
                id,
                containerID: self.id,
                spec: spec,
                io: stdio,
                agent: agent,
                vm: state.vm,
                logger: self.logger
            )
            return process
        }
    }

    /// Execute a new process in the container. The process is not started after this call, and must be manually started
    /// via the `start` method.
    public func exec(_ id: String, configuration: LinuxProcessConfiguration) async throws -> LinuxProcess {
        try await self.state.withLock {
            let state = try $0.startedState("exec")

            var spec = self.generateRuntimeSpec()
            spec.process = configuration.toOCI()

            let stdio = Self.setupIO(
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
                agent: agent,
                vm: state.vm,
                logger: self.logger
            )

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

        if socket.direction == .into {
            socket.destination = rootInGuest.appending(path: socket.destination.path)
        } else {
            socket.source = rootInGuest.appending(path: socket.source.path)
        }

        let port = self.hostVsockPorts.wrappingAdd(1, ordering: .relaxed).oldValue
        try await relayManager.start(port: port, socket: socket)
        try await relayAgent.relaySocket(port: port, configuration: socket)
    }
}

extension VirtualMachineInstance {
    /// Scoped access to an agent instance to ensure the resources are always freed (mostly close(2)'ing
    /// the vsock fd)
    fileprivate func withAgent<T>(fn: @Sendable (VirtualMachineAgent) async throws -> T) async throws -> T {
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
    fileprivate var to: ContainerizationOCI.Mount {
        .init(
            type: self.type,
            source: self.source,
            destination: self.destination,
            options: self.options
        )
    }
}

#endif
