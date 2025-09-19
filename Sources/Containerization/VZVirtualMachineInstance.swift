//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

struct VZVirtualMachineInstance: VirtualMachineInstance, Sendable {
    typealias Agent = Vminitd

    /// Cleanup registry for temporary directories
    private static let tempDirectoryCleanup = Mutex<Set<String>>(Set<String>())

    /// Register a temporary directory for cleanup
    public static func registerTempDirectory(_ path: String) {
        _ = tempDirectoryCleanup.withLock { $0.insert(path) }
    }

    /// Clean up all registered temporary directories
    public static func cleanupTempDirectories() {
        let directoriesToClean = tempDirectoryCleanup.withLock {
            let dirs = Array($0)
            $0.removeAll()
            return dirs
        }

        for directory in directoriesToClean {
            do {
                try FileManager.default.removeItem(atPath: directory)
            } catch {
                // Log but don't fail - cleanup is best effort
                print("Warning: Failed to cleanup temporary directory \(directory): \(error)")
            }
        }
    }

    /// Attached mounts on the sandbox.
    public let mounts: [AttachedFilesystem]

    /// Returns the runtime state of the vm.
    public var state: VirtualMachineInstanceState {
        vzStateToInstanceState()
    }

    /// The sandbox configuration.
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
        /// Mount attachments.
        public var mounts: [Mount]
        /// Network interface attachments.
        public var interfaces: [any Interface]
        /// Kernel image.
        public var kernel: Kernel?
        /// The root filesystem.
        public var initialFilesystem: Mount?
        /// File path to store the sandbox boot logs.
        public var bootlog: URL?
        /// Cached consolidated mounts (computed once and reused).
        private var consolidatedMountsCache: [Mount]?

        init() {
            self.cpus = 4
            self.memoryInBytes = 1024.mib()
            self.rosetta = false
            self.nestedVirtualization = false
            self.mounts = []
            self.interfaces = []
            self.consolidatedMountsCache = nil
        }

        /// Returns consolidated mounts, computing and caching them on first access.
        mutating func consolidatedMounts() throws -> [Mount] {
            if let cached = consolidatedMountsCache {
                return cached
            }

            let consolidated = try consolidateMounts(self.mounts)
            consolidatedMountsCache = consolidated
            return consolidated
        }
    }

    // `vm` isn't used concurrently.
    private nonisolated(unsafe) let vm: VZVirtualMachine
    private let queue: DispatchQueue
    private let group: MultiThreadedEventLoopGroup
    private let lock: AsyncLock
    private let timeSyncer: TimeSyncer
    private let logger: Logger?

    public init(
        group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
        logger: Logger? = nil,
        with: (inout Configuration) throws -> Void
    ) throws {
        var config = Configuration()
        try with(&config)
        try self.init(group: group, config: config, logger: logger)
    }

    init(group: MultiThreadedEventLoopGroup, config: Configuration, logger: Logger?) throws {
        var mutableConfig = config
        self.config = config
        self.group = group
        self.lock = .init()
        self.queue = DispatchQueue(label: "com.apple.containerization.sandbox.\(UUID().uuidString)")
        self.mounts = try mutableConfig.mountAttachments()
        self.logger = logger
        self.timeSyncer = .init(logger: logger)

        self.vm = VZVirtualMachine(
            configuration: try mutableConfig.toVZ(),
            queue: self.queue
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

    func start() async throws {
        try await lock.withLock { _ in
            guard self.state == .stopped else {
                throw ContainerizationError(
                    .invalidState,
                    message: "sandbox is not stopped \(self.state)"
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
        try await lock.withLock { _ in
            // NOTE: We should record HOW the vm stopped eventually. If the vm exited
            // unexpectedly virtualization framework offers you a way to store
            // an error on how it exited. We should report that here instead of the
            // generic vm is not running.
            guard self.state == .running else {
                throw ContainerizationError(.invalidState, message: "vm is not running")
            }

            try await self.timeSyncer.close()

            try await self.vm.stop(queue: self.queue)
            try await self.group.shutdownGracefully()
        }
    }

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
        let conn = try await dial(Vminitd.port)
        return Vminitd(connection: conn, group: self.group)
    }
}

extension VZVirtualMachineInstance {
    func dial(_ port: UInt32) async throws -> FileHandle {
        try await vm.connect(
            queue: queue,
            port: port
        ).dupHandle()
    }

    func listen(_ port: UInt32) throws -> VsockConnectionStream {
        let stream = VsockConnectionStream(port: port)
        let listener = VZVirtioSocketListener()
        listener.delegate = stream

        try self.vm.listen(
            queue: queue,
            port: port,
            listener: listener
        )
        return stream
    }

    func stopListen(_ port: UInt32) throws {
        try self.vm.removeListener(
            queue: queue,
            port: port
        )
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

    private func serialPort(path: URL) throws -> [VZVirtioConsoleDeviceSerialPortConfiguration] {
        let c = VZVirtioConsoleDeviceSerialPortConfiguration()
        c.attachment = try VZFileSerialPortAttachment(url: path, append: true)
        return [c]
    }

    mutating func toVZ() throws -> VZVirtualMachineConfiguration {
        var config = VZVirtualMachineConfiguration()

        config.cpuCount = self.cpus
        config.memorySize = self.memoryInBytes
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        if let bootlog = self.bootlog {
            config.serialPorts = try serialPort(path: bootlog)
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

        // Use consolidated mounts for VirtioFS share configuration
        let consolidatedMounts = try self.consolidatedMounts()
        for mount in consolidatedMounts {
            try mount.configure(config: &config)
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

    mutating func mountAttachments() throws -> [AttachedFilesystem] {
        let allocator = Character.blockDeviceTagAllocator()
        if let initialFilesystem {
            // When the initial filesystem is a blk, allocate the first letter "vd(a)"
            // as that is what this blk will be attached under.
            if initialFilesystem.isBlock {
                _ = try allocator.allocate()
            }
        }

        // Use cached consolidated mounts (same as toVZ() to ensure hash consistency)
        let consolidatedMounts = try self.consolidatedMounts()

        var attachments: [AttachedFilesystem] = []
        for mount in consolidatedMounts {
            let attachment = try AttachedFilesystem(mount: mount, allocator: allocator)
            attachments.append(attachment)
        }

        return attachments
    }

    private func consolidateMounts(_ mounts: [Mount]) throws -> [Mount] {
        var consolidatedMounts: [Mount] = []
        var fileMountsByParent: [String: [Mount]] = [:]

        // Group file mounts by parent directory
        for mount in mounts {
            if mount.isFile && mount.type == "virtiofs" {
                let parentDir = URL(fileURLWithPath: mount.destination).deletingLastPathComponent().path
                fileMountsByParent[parentDir, default: []].append(mount)
            } else {
                // Non-file mounts go directly to consolidated list
                consolidatedMounts.append(mount)
            }
        }

        // Create consolidated mounts for each parent directory
        for (parentDir, fileMounts) in fileMountsByParent {
            // Both single and multiple file mounts need consolidation to ensure consistent VirtioFS tags
            let consolidatedMount = try createConsolidatedMount(fileMounts: fileMounts, parentDir: parentDir)
            consolidatedMounts.append(consolidatedMount)
        }

        return consolidatedMounts
    }

    private func createConsolidatedMount(fileMounts: [Mount], parentDir: String) throws -> Mount {
        // Create a consolidated directory containing all the files
        let consolidatedHash = try hashMountSources(sources: fileMounts.map { $0.source })
        let consolidatedTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("containerization-consolidated-\(consolidatedHash)")

        // Atomically create directory to prevent TOCTOU race condition
        try createConsolidatedDirectoryAtomically(at: consolidatedTempDir, fileMounts: fileMounts)

        // Create a consolidated mount targeting the parent directory
        let consolidatedMount = Mount.share(source: consolidatedTempDir.path, destination: parentDir)
        return consolidatedMount
    }

    /// Atomically create consolidated directory and populate with hardlinks
    private func createConsolidatedDirectoryAtomically(at url: URL, fileMounts: [Mount]) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Register for cleanup if this is a containerization temp directory
            if url.path.contains("containerization-consolidated-") {
                VZVirtualMachineInstance.registerTempDirectory(url.path)
            }

            // Create hardlinks for all files with their destination filenames
            for mount in fileMounts {
                // Validate each source file before creating hardlink
                try validateSourceFileForMount(mount)

                let destinationFilename = URL(fileURLWithPath: mount.destination).lastPathComponent
                let consolidatedFile = url.appendingPathComponent(destinationFilename)
                let sourceFile = URL(fileURLWithPath: mount.source)
                try FileManager.default.linkItem(at: sourceFile, to: consolidatedFile)
            }
        } catch CocoaError.fileWriteFileExists {
            // Directory already exists, verify it's actually a directory and has expected contents
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw ContainerizationError(.invalidArgument, message: "Path exists but is not a directory: \(url.path)")
            }

            // Verify all expected hardlinks exist
            for mount in fileMounts {
                let destinationFilename = URL(fileURLWithPath: mount.destination).lastPathComponent
                let consolidatedFile = url.appendingPathComponent(destinationFilename)
                if !FileManager.default.fileExists(atPath: consolidatedFile.path) {
                    // Missing hardlink, create it
                    try validateSourceFileForMount(mount)
                    let sourceFile = URL(fileURLWithPath: mount.source)
                    try FileManager.default.linkItem(at: sourceFile, to: consolidatedFile)
                }
            }
        } catch {
            throw ContainerizationError(.internalError, message: "Failed to create consolidated directory \(url.path): \(error.localizedDescription)")
        }
    }

    /// Validate source file for mount (extracted to avoid duplication)
    private func validateSourceFileForMount(_ mount: Mount) throws {
        let source = mount.source

        // Check if file exists
        guard FileManager.default.fileExists(atPath: source) else {
            throw ContainerizationError(.notFound, message: "Source file does not exist: \(source)")
        }

        // Get file attributes to check if it's a regular file
        let attributes = try FileManager.default.attributesOfItem(atPath: source)
        let fileType = attributes[.type] as? FileAttributeType

        // Reject symlinks to prevent following links to unintended targets
        guard fileType != .typeSymbolicLink else {
            throw ContainerizationError(.invalidArgument, message: "Cannot mount symlink: \(source)")
        }

        // Ensure it's a regular file
        guard fileType == .typeRegular else {
            throw ContainerizationError(.invalidArgument, message: "Source must be a regular file: \(source)")
        }

        // Check if file is readable
        guard FileManager.default.isReadableFile(atPath: source) else {
            throw ContainerizationError(.invalidArgument, message: "Source file is not readable: \(source)")
        }
    }

    private func hashMountSources(sources: [String]) throws -> String {
        // Create a deterministic hash of all source paths for consolidated mount
        // Sanitize paths by escaping the separator character to prevent hash collisions
        let sanitizedSources = sources.sorted().map { source in
            source.replacingOccurrences(of: "|", with: "\\|")
        }
        let combined = sanitizedSources.joined(separator: "|")
        return try hashMountSource(source: combined)
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
            guard let mac = VZMACAddress(string: macAddress) else {
                throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
            }
            config.macAddress = mac
        }
        config.attachment = VZNATNetworkDeviceAttachment()
        return config
    }
}

#endif
