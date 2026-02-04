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
import Foundation
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Logging
import NIOCore
import NIOPosix
import Synchronization
import Virtualization

struct VZVirtualMachineInstance: Sendable {
    typealias Agent = Vminitd

    /// Attached mounts on the virtual machine, organized by metadata ID.
    public let mounts: [String: [AttachedFilesystem]]

    /// Returns the runtime state of the vm.
    public var state: VirtualMachineInstanceState {
        vzStateToInstanceState()
    }

    /// The virtual machine instance configuration.
    private let config: Configuration
    public struct Configuration: Sendable {
        /// Amount of cpus to allocated.
        public var cpus: Int
        /// Amount of memory in bytes allocated.
        public var memoryInBytes: UInt64
        /// Toggle rosetta's x86_64 emulation support.
        public var rosetta: Bool
        /// Toggle nested virtualization support.
        public var nestedVirtualization: Bool
        /// Mount attachments organized by metadata ID.
        public var mountsByID: [String: [Mount]]
        /// Network interface attachments.
        public var interfaces: [any Interface]
        /// Kernel image.
        public var kernel: Kernel?
        /// The root filesystem.
        public var initialFilesystem: Mount?
        /// Destination for the virtual machine's boot logs.
        public var bootLog: BootLog?

        init() {
            self.cpus = 4
            self.memoryInBytes = 1024.mib()
            self.rosetta = false
            self.nestedVirtualization = false
            self.mountsByID = [:]
            self.interfaces = []
        }
    }

    // `vm` isn't used concurrently.
    private nonisolated(unsafe) let vm: VZVirtualMachine
    private let queue: DispatchQueue
    private let lock: AsyncLock
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let timeSyncer: TimeSyncer
    private let logger: Logger?

    public init(
        group: EventLoopGroup? = nil,
        logger: Logger? = nil,
        with: (inout Configuration) throws -> Void
    ) throws {
        var config = Configuration()
        try with(&config)
        try self.init(group: group, config: config, logger: logger)
    }

    init(group: EventLoopGroup?, config: Configuration, logger: Logger?) throws {
        if let group {
            self.ownsGroup = false
            self.group = group
        } else {
            self.ownsGroup = true
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        }

        self.config = config
        self.lock = .init()
        self.queue = DispatchQueue(label: "com.apple.containerization.vzvm.\(UUID().uuidString)")
        self.mounts = try config.mountAttachments()
        self.logger = logger
        self.timeSyncer = .init(logger: logger)

        self.vm = VZVirtualMachine(
            configuration: try config.toVZ(),
            queue: self.queue
        )
    }
}

extension VZVirtualMachineInstance: VirtualMachineInstance {
    func start() async throws {
        try await lock.withLock { _ in
            guard self.state == .stopped else {
                throw ContainerizationError(
                    .invalidState,
                    message: "virtual machine is not stopped \(self.state)"
                )
            }

            // Do any necessary setup needed prior to starting the guest.
            try await self.prestart()

            try await self.vm.start(queue: self.queue)

            let agent = Vminitd(
                connection: try await self.vm.waitForAgent(queue: self.queue),
                group: self.group
            )

            do {
                if self.config.rosetta {
                    try await agent.enableRosetta()
                }
            } catch {
                try await agent.close()
                throw error
            }

            // Don't close our remote context as we are providing
            // it to our time sync routine.
            await self.timeSyncer.start(context: agent)
        }
    }

    func stop() async throws {
        try await lock.withLock { connections in
            // NOTE: We should record HOW the vm stopped eventually. If the vm exited
            // unexpectedly virtualization framework offers you a way to store
            // an error on how it exited. We should report that here instead of the
            // generic vm is not running.
            guard self.state == .running else {
                throw ContainerizationError(.invalidState, message: "vm is not running")
            }

            try await self.timeSyncer.close()

            if self.ownsGroup {
                try await self.group.shutdownGracefully()
            }

            try await self.vm.stop(queue: self.queue)
        }
    }

    // NOTE: Investigate what is the "right" way to handle already vended vsock
    // connections for pause and resume.

    func pause() async throws {
        try await lock.withLock { _ in
            await self.timeSyncer.pause()
            try await self.vm.pause(queue: self.queue)
        }
    }

    func resume() async throws {
        try await lock.withLock { _ in
            try await self.vm.resume(queue: self.queue)
            await self.timeSyncer.resume()
        }
    }

    public func dialAgent() async throws -> Vminitd {
        try await lock.withLock { _ in
            do {
                let conn = try await vm.connect(
                    queue: queue,
                    port: Vminitd.port
                )
                let handle = try conn.dupHandle()
                let agent = Vminitd(connection: handle, group: self.group)
                return agent
            } catch {
                if let err = error as? ContainerizationError {
                    throw err
                }
                throw ContainerizationError(
                    .internalError,
                    message: "failed to dial agent",
                    cause: error
                )
            }
        }
    }

    func dial(_ port: UInt32) async throws -> FileHandle {
        try await lock.withLock { _ in
            do {
                let conn = try await vm.connect(
                    queue: queue,
                    port: port
                )
                return try conn.dupHandle()
            } catch {
                if let err = error as? ContainerizationError {
                    throw err
                }
                throw ContainerizationError(
                    .internalError,
                    message: "failed to dial vsock port",
                    cause: error
                )
            }
        }
    }

    func listen(_ port: UInt32) throws -> VsockListener {
        let stream = VsockListener(port: port, stopListen: self.stopListen)
        let listener = VZVirtioSocketListener()
        listener.delegate = stream

        try self.vm.listen(
            queue: queue,
            port: port,
            listener: listener
        )
        return stream
    }

    private func stopListen(_ port: UInt32) throws {
        try self.vm.removeListener(
            queue: queue,
            port: port
        )
    }
}

extension VZVirtualMachineInstance {
    func vzStateToInstanceState() -> VirtualMachineInstanceState {
        self.queue.sync {
            let state: VirtualMachineInstanceState
            switch self.vm.state {
            case .starting:
                state = .starting
            case .running:
                state = .running
            case .stopping:
                state = .stopping
            case .stopped:
                state = .stopped
            default:
                state = .unknown
            }
            return state
        }
    }

    func prestart() async throws {
        if self.config.rosetta {
            #if arch(arm64)
            if VZLinuxRosettaDirectoryShare.availability == .notInstalled {
                self.logger?.info("installing rosetta")
                try await VZVirtualMachineInstance.Configuration.installRosetta()
            }
            #else
            fatalError("rosetta is only supported on arm64")
            #endif
        }
    }
}

extension VZVirtualMachineInstance.Configuration {
    public static func installRosetta() async throws {
        do {
            #if arch(arm64)
            try await VZLinuxRosettaDirectoryShare.installRosetta()
            #else
            fatalError("rosetta is only supported on arm64")
            #endif
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to install rosetta",
                cause: error
            )
        }
    }

    private func serialPort(destination: BootLog) throws -> [VZVirtioConsoleDeviceSerialPortConfiguration] {
        let c = VZVirtioConsoleDeviceSerialPortConfiguration()
        switch destination.base {
        case .file(let path, let append):
            c.attachment = try VZFileSerialPortAttachment(url: path, append: append)
        case .fileHandle(let fileHandle):
            c.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil,
                fileHandleForWriting: fileHandle
            )
        }
        return [c]
    }

    func toVZ() throws -> VZVirtualMachineConfiguration {
        var config = VZVirtualMachineConfiguration()

        config.cpuCount = self.cpus
        config.memorySize = self.memoryInBytes
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if let bootLog = self.bootLog {
            config.serialPorts = try serialPort(destination: bootLog)
        } else {
            // We always supply a serial console. If no explicit path was provided just send em to the void.
            config.serialPorts = try serialPort(destination: .file(path: URL(filePath: "/dev/null")))
        }

        config.networkDevices = try self.interfaces.map {
            guard let vzi = $0 as? VZInterface else {
                throw ContainerizationError(.invalidArgument, message: "interface type not supported by VZ")
            }
            return try vzi.device()
        }

        if self.rosetta {
            #if arch(arm64)
            switch VZLinuxRosettaDirectoryShare.availability {
            case .notSupported:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "rosetta was requested but is not supported on this machine"
                )
            case .notInstalled:
                // NOTE: If rosetta isn't installed, we'll error with a nice error message
                // during .start() of the virtual machine instance.
                fallthrough
            case .installed:
                let share = try VZLinuxRosettaDirectoryShare()
                let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                device.share = share
                config.directorySharingDevices.append(device)
            @unknown default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "unknown rosetta availability encountered: \(VZLinuxRosettaDirectoryShare.availability)"
                )
            }
            #else
            fatalError("rosetta is only supported on arm64")
            #endif
        }

        guard let kernel = self.kernel else {
            throw ContainerizationError(.invalidArgument, message: "kernel cannot be nil")
        }

        guard let initialFilesystem = self.initialFilesystem else {
            throw ContainerizationError(.invalidArgument, message: "rootfs cannot be nil")
        }

        let loader = VZLinuxBootLoader(kernelURL: kernel.path)
        loader.commandLine = kernel.linuxCommandline(initialFilesystem: initialFilesystem)
        config.bootLoader = loader

        try initialFilesystem.configure(config: &config)
        for (_, mounts) in self.mountsByID {
            for mount in mounts {
                try mount.configure(config: &config)
            }
        }

        let platform = VZGenericPlatformConfiguration()
        // We shouldn't silently succeed if the user asked for virt and their hardware does
        // not support it.
        if !VZGenericPlatformConfiguration.isNestedVirtualizationSupported && self.nestedVirtualization {
            throw ContainerizationError(
                .unsupported,
                message: "nested virtualization is not supported on the platform"
            )
        }
        platform.isNestedVirtualizationEnabled = self.nestedVirtualization
        config.platform = platform

        try config.validate()
        return config
    }

    func mountAttachments() throws -> [String: [AttachedFilesystem]] {
        let allocator = Character.blockDeviceTagAllocator()
        if let initialFilesystem {
            // When the initial filesystem is a blk, allocate the first letter "vd(a)"
            // as that is what this blk will be attached under.
            if initialFilesystem.isBlock {
                _ = try allocator.allocate()
            }
        }

        var attachmentsByID: [String: [AttachedFilesystem]] = [:]
        for (id, mounts) in self.mountsByID {
            var attachments: [AttachedFilesystem] = []
            for mount in mounts {
                attachments.append(try .init(mount: mount, allocator: allocator))
            }
            attachmentsByID[id] = attachments
        }
        return attachmentsByID
    }
}

extension Mount {
    var isBlock: Bool {
        type == "ext4"
    }
}

extension Kernel {
    func linuxCommandline(initialFilesystem: Mount) -> String {
        var args = self.commandLine.kernelArgs

        args.append("init=/sbin/vminitd")
        // rootfs is always set as ro.
        args.append("ro")

        switch initialFilesystem.type {
        case "virtiofs":
            args.append(contentsOf: [
                "rootfstype=virtiofs",
                "root=rootfs",
            ])
        case "ext4":
            args.append(contentsOf: [
                "rootfstype=ext4",
                "root=/dev/vda",
            ])
        default:
            fatalError("unsupported initfs filesystem \(initialFilesystem.type)")
        }

        if self.commandLine.initArgs.count > 0 {
            args.append("--")
            args.append(contentsOf: self.commandLine.initArgs)
        }

        return args.joined(separator: " ")
    }
}

public protocol VZInterface {
    func device() throws -> VZVirtioNetworkDeviceConfiguration
}

extension NATInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress.description) else {
                throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
            }
            config.macAddress = mac
        }
        config.attachment = VZNATNetworkDeviceAttachment()
        return config
    }
}

#endif
