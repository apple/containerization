//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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
import SendableProperty

import struct ContainerizationOS.Terminal

/// `LinuxContainer` is an easy to use type for launching and managing the
/// full lifecycle of a Linux container ran inside of a virtual machine.
///
/// NOTE: Editing the properties of `LinuxContainer` after calling `start()`
/// have no effect.
public final class LinuxContainer: Container, Sendable {
    /// The default PATH value for a process.
    public static let defaultPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    /// The identifier of the container.
    public let id: String

    /// Rootfs for the container.
    public let rootfs: Mount

    private struct Configuration {
        var spec: Spec
        var cpus: Int = 4
        var memoryInBytes: UInt64 = 1024.mib()
        var interfaces: [any Interface] = []
        var sockets: [UnixSocketConfiguration] = []
        var rosetta: Bool = false
        var virtualization: Bool = false
        var terminal: Terminal? = nil
        var ioHandlers: LinuxProcess.IOHandler = .nullIO()
        var mounts: [Mount]
        var dns: DNS? = nil
    }

    @SendableProperty
    private var state: State

    @SendableProperty
    private var config: Configuration
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
        /// The container is creating and booting the underlying virtual resources.
        case creating(CreatingState)
        /// The container's virtual machine has been setup and the runtime environment has been configured.
        case created(CreatedState)
        /// The initial process of the container is preparing to start.
        case starting(StartingState)
        /// The initial process of the container has started and is running.
        case started(StartedState)
        /// The container is preparing to stop.
        case stopping(StoppingState)
        /// The container has ran and fully stopped.
        case stopped
        /// An error occurred during the lifetime of this class.
        case errored(Swift.Error)

        struct CreatingState: Sendable {}

        struct CreatedState: Sendable {
            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager
        }

        struct StartingState: Sendable {
            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager

            init(_ state: CreatedState) {
                self.vm = state.vm
                self.relayManager = state.relayManager
            }
        }

        struct StartedState: Sendable {
            let vm: any VirtualMachineInstance
            let process: LinuxProcess
            let relayManager: UnixSocketRelayManager

            init(_ state: StartingState, process: LinuxProcess) {
                self.vm = state.vm
                self.relayManager = state.relayManager
                self.process = process
            }
        }

        struct StoppingState: Sendable {
            let vm: any VirtualMachineInstance

            init(_ state: StartedState) {
                self.vm = state.vm
            }
        }

        mutating func setCreating() throws {
            switch self {
            case .initialized:
                self = .creating(.init())
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container must be in initialized state to start"
                )
            }
        }

        mutating func setCreated(
            vm: any VirtualMachineInstance,
            relayManager: UnixSocketRelayManager
        ) throws {
            switch self {
            case .creating:
                self = .created(.init(vm: vm, relayManager: relayManager))
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container must be in creating state before created"
                )

            }
        }

        mutating func setStarting() throws -> any VirtualMachineInstance {
            switch self {
            case .created(let state):
                self = .starting(.init(state))
                return state.vm
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container must be in created state before starting"
                )
            }
        }

        mutating func setStarted(process: LinuxProcess) throws {
            switch self {
            case .starting(let state):
                self = .started(.init(state, process: process))
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container must be in starting state before started"
                )
            }
        }

        mutating func stopping() throws -> StartedState {
            switch self {
            case .started(let state):
                self = .stopping(.init(state))
                return state
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container must be in a started state before stopping"
                )
            }
        }

        func startedState(_ operation: String) throws -> StartedState {
            switch self {
            case .started(let state):
                return state
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to \(operation): container must be running"
                )
            }
        }

        mutating func stopped() throws {
            switch self {
            case .stopping(_):
                self = .stopped
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container must be in a stopping state before setting to stopped"
                )
            }
        }

        mutating func errored(error: Swift.Error) {
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
        logger: Logger? = nil
    ) {
        self.id = id
        self.vmm = vmm
        self.hostVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.guestVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.rootfs = rootfs
        self.logger = logger
        self.config = Configuration(
            spec: Self.createDefaultRuntimeSpec(id),
            mounts: Self.createDefaultMounts()
        )
        self.state = .initialized
    }

    private static func createDefaultRuntimeSpec(_ id: String) -> Spec {
        .init(
            process: .init(
                cwd: "/",
                env: ["PATH=\(Self.defaultPath)"]
            ),
            hostname: id,
            root: .init(
                path: Self.guestRootfsPath(id),
                readonly: false
            ),
            linux: .init(
                resources: .init()
            )
        )
    }

    private static func guestRootfsPath(_ id: String) -> String {
        "/run/container/\(id)/rootfs"
    }

    private static func createDefaultMounts() -> [Mount] {
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
}

extension LinuxContainer {
    package var root: String {
        self.config.spec.root!.path
    }

    /// Number of CPU cores allocated.
    public var cpus: Int {
        get {
            config.cpus
        }
        set {
            config.cpus = newValue
        }
    }

    /// Amount of memory in bytes allocated for the container.
    /// This will be aligned to a 1MB boundary if it isn't already.
    public var memoryInBytes: UInt64 {
        get {
            config.memoryInBytes
        }
        set {
            config.memoryInBytes = newValue
        }
    }

    /// Network interfaces of the container.
    public var interfaces: [any Interface] {
        get {
            config.interfaces
        }
        set {
            config.interfaces = newValue
        }
    }

    /// DNS configuration for the container.
    public var dns: DNS? {
        get { config.dns }
        set { config.dns = newValue }
    }

    /// Unix sockets to share into or out of the container.
    ///
    /// The VirtualMachineAgent used to launch the container
    /// MUST conform to `SocketRelayAgent` to support this, otherwise
    /// a ContainerizationError will be returned on start with the code
    /// set to `.unsupported`.
    public var sockets: [UnixSocketConfiguration] {
        get {
            config.sockets
        }
        set {
            config.sockets = newValue
        }
    }

    /// Enable/disable x86-64 emulation in the container.
    public var rosetta: Bool {
        get {
            config.rosetta
        }
        set {
            config.rosetta = newValue
        }
    }

    /// Enable/disable virtualization capabilities in the container.
    public var virtualization: Bool {
        get {
            config.virtualization
        }
        set {
            config.virtualization = newValue
        }
    }

    /// Filesystem mounts for the container.
    public var mounts: [Mount] {
        get {
            config.mounts
        }
        set {
            config.mounts = newValue
        }
    }

    /// Arguments passed to the container.
    public var arguments: [String] {
        get {
            config.spec.process!.args
        }
        set {
            config.spec.process!.args = newValue
        }
    }

    /// Environment variables for the container.
    public var environment: [String] {
        get { config.spec.process!.env }
        set { config.spec.process!.env = newValue }
    }

    /// The current working directory (cwd) for the container.
    public var workingDirectory: String {
        get { config.spec.process!.cwd }
        set { config.spec.process!.cwd = newValue }
    }

    /// The User the container should execute under.
    public var user: ContainerizationOCI.User {
        get { config.spec.process!.user }
        set { config.spec.process!.user = newValue }
    }

    /// Set the hostname for the container.
    public var hostname: String {
        get { config.spec.hostname }
        set { config.spec.hostname = newValue }
    }

    /// Set any sysctls for the container's environment.
    public var sysctl: [String: String]? {
        get { config.spec.linux!.sysctl }
        set { config.spec.linux!.sysctl = newValue }
    }

    /// Rlimits for the container.
    public var rlimits: [POSIXRlimit] {
        get { config.spec.process!.rlimits }
        set { config.spec.process!.rlimits = newValue }
    }
}

extension LinuxContainer {
    /// Set a pty device as the container's stdio.
    public var terminalDevice: Terminal? {
        get { config.terminal }
        set {
            config.spec.process!.terminal = newValue != nil ? true : false
            config.terminal = newValue
            config.ioHandlers.stdin = newValue
            config.ioHandlers.stdout = newValue
            config.ioHandlers.stderr = nil
        }
    }

    /// If the container has a pty allocated.
    public var terminal: Bool {
        get { config.spec.process!.terminal }
        set { config.spec.process!.terminal = newValue }
    }

    /// Set the stdin stream for the initial process of the container.
    public var stdin: ReaderStream? {
        get {
            config.ioHandlers.stdin
        }
        set {
            config.ioHandlers.stdin = newValue
        }
    }

    /// Set the stdout handler for the initial process of the container.
    public var stdout: Writer? {
        get {
            config.ioHandlers.stdout
        }
        set {
            config.ioHandlers.stdout = newValue
        }
    }

    /// Set the stderr handler for the initial process of the container.
    public var stderr: Writer? {
        get {
            config.ioHandlers.stderr
        }
        set {
            config.ioHandlers.stderr = newValue
        }
    }

    public func setProcessConfig(from imageConfig: ImageConfig) {
        let process = ContainerizationOCI.Process(from: imageConfig)
        self.config.spec.process = process
    }
}

extension LinuxContainer {
    /// Create the underlying container's virtual machine
    /// and setup the runtime environment.
    public func create() async throws {
        try state.setCreating()

        let vm = try vmm.create(container: self)
        try await vm.start()

        let agent = try await vm.dialAgent()
        do {
            let relayManager = UnixSocketRelayManager(vm: vm)

            try await agent.standardSetup()

            // Mount the rootfs.
            var rootfs = vm.mounts[0].to
            rootfs.destination = Self.guestRootfsPath(self.id)
            try await agent.mount(rootfs)

            // Start up our friendly unix socket relays.
            for socket in self.sockets {
                try await self.relayUnixSocket(
                    socket: socket,
                    relayManager: relayManager,
                    agent: agent
                )
            }

            for (index, i) in self.interfaces.enumerated() {
                let name = "eth\(index)"
                try await agent.addressAdd(name: name, address: i.address)
                try await agent.up(name: name)
                try await agent.routeAddDefault(name: name, gateway: i.gateway)
            }
            if let dns = self.dns {
                try await agent.configureDNS(config: dns, location: rootfs.destination)
            }

            try state.setCreated(vm: vm, relayManager: relayManager)
        } catch {
            try? await agent.close()
            try? await vm.stop()

            state.errored(error: error)
            throw error
        }
    }

    /// Start the container container's initial process.
    public func start() async throws {
        let vm = try state.setStarting()

        let agent = try await vm.dialAgent()
        do {
            var specCopy = config.spec
            // We don't need the rootfs, nor do OCI runtimes want it included.
            specCopy.mounts = vm.mounts.dropFirst().map { $0.to }

            let stdio = Self.setupIO(
                portAllocator: self.hostVsockPorts,
                stdin: self.stdin,
                stdout: self.stdout,
                stderr: self.stderr
            )

            let process = LinuxProcess(
                self.id,
                containerID: self.id,
                spec: specCopy,
                io: stdio,
                agent: agent,
                vm: vm,
                logger: self.logger
            )
            try await process.start()

            try state.setStarted(process: process)
        } catch {
            try? await agent.close()

            state.errored(error: error)
            throw error
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
}

extension LinuxContainer {
    /// Stop the container from executing.
    public func stop() async throws {
        let startedState = try state.stopping()

        try await startedState.relayManager.stopAll()

        // It's possible the state of the vm is not in a great spot
        // if the guest panicked or had any sort of bug/fault.
        // First check if the vm is even still running, as trying to
        // use a vsock handle like below here will cause NIO to
        // fatalError because we'll get an EBADF.
        if startedState.vm.state == .stopped {
            try state.stopped()
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
        try state.stopped()
    }

    /// Send a signal to the container.
    public func kill(_ signal: Int32) async throws {
        let state = try self.state.startedState("kill")
        try await state.process.kill(signal)
    }

    /// Wait for the container to exit. Returns the exit code.
    @discardableResult
    public func wait(timeoutInSeconds: Int64? = nil) async throws -> Int32 {
        let state = try self.state.startedState("wait")
        return try await state.process.wait(timeoutInSeconds: timeoutInSeconds)
    }

    /// Resize the container's terminal (if one was requested). This
    /// will error if terminal was set to false before creating the container.
    public func resize(to: Terminal.Size) async throws {
        let state = try self.state.startedState("resize")
        try await state.process.resize(to: to)
    }
}

extension LinuxContainer {
    /// Execute a new process in the container.
    public func exec(
        _ id: String,
        configuration: ContainerizationOCI.Process,
        stdin: ReaderStream? = nil,
        stdout: Writer? = nil,
        stderr: Writer? = nil
    ) async throws -> LinuxProcess {
        let state = try self.state.startedState("exec")

        var specCopy = config.spec
        specCopy.process = configuration

        let stdio = Self.setupIO(
            portAllocator: self.hostVsockPorts,
            stdin: stdin,
            stdout: stdout,
            stderr: stderr
        )
        let agent = try await state.vm.dialAgent()
        let process = LinuxProcess(
            id,
            containerID: self.id,
            spec: specCopy,
            io: stdio,
            agent: agent,
            vm: state.vm,
            logger: self.logger
        )
        return process
    }

    /// Dial a vsock port in the container.
    public func dialVsock(port: UInt32) async throws -> FileHandle {
        let state = try self.state.startedState("dialVsock")
        return try await state.vm.dial(port)
    }

    /// Relay a unix socket from in the container to the host, or from the host
    /// to inside the container.
    public func relayUnixSocket(socket: UnixSocketConfiguration) async throws {
        let state = try self.state.startedState("relayUnixSocket")

        let agent = try await state.vm.dialAgent()
        try await self.relayUnixSocket(
            socket: socket,
            relayManager: state.relayManager,
            agent: agent
        )
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
    fileprivate func withAgent(fn: @Sendable (VirtualMachineAgent) async throws -> Void) async throws {
        let agent = try await self.dialAgent()
        do {
            try await fn(agent)
            try await agent.close()
        } catch {
            try await agent.close()
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
