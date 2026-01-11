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
import ContainerizationOCI
import ContainerizationOS
import Foundation
import ContainerizationExtras
import Virtualization
import vmnet

/// A manager for creating and running containers.
/// Supports container networking options.
public struct ContainerManager: Sendable {
    public let imageStore: ImageStore
    private let vmm: VirtualMachineManager
    private var network: Network?

    private var containerRoot: URL {
        self.imageStore.path.appendingPathComponent("containers")
    }

    /// A network that can allocate and release interfaces for use with containers.
    public protocol Network: Sendable {
        mutating func create(_ id: String) throws -> Interface?
        mutating func release(_ id: String) throws
    }

    /// A network backed by vmnet on macOS.
    @available(macOS 26.0, *)
    public struct VmnetNetwork: Network {
        private var allocator: Allocator
        // `reference` isn't used concurrently.
        nonisolated(unsafe) private let reference: vmnet_network_ref

        /// The IPv4 subnet of this network.
        public let subnet: CIDRv4

        /// The IPv4 gateway address of this network.
        public var ipv4Gateway: IPv4Address {
            subnet.gateway
        }

        struct Allocator: Sendable {
            private let addressAllocator: any AddressAllocator<UInt32>
            private let cidr: CIDRv4
            private var allocations: [String: UInt32]

            init(cidr: CIDRv4) throws {
                self.cidr = cidr
                self.allocations = .init()
                let size = Int(cidr.upper.value - cidr.lower.value - 3)
                self.addressAllocator = try UInt32.rotatingAllocator(
                    lower: cidr.lower.value + 2,
                    size: UInt32(size)
                )
            }

            mutating func allocate(_ id: String) throws -> CIDRv4 {
                if allocations[id] != nil {
                    throw ContainerizationError(.exists, message: "allocation with id \(id) already exists")
                }
                let index = try addressAllocator.allocate()
                allocations[id] = index
                let ip = IPv4Address(index)
                return try CIDRv4(ip, prefix: cidr.prefix)
            }

            mutating func release(_ id: String) throws {
                if let index = self.allocations[id] {
                    try addressAllocator.release(index)
                    allocations.removeValue(forKey: id)
                }
            }
        }

        /// A network interface supporting the vmnet_network_ref.
        public struct Interface: Containerization.Interface, VZInterface, Sendable {
            public let ipv4Address: CIDRv4
            public let ipv4Gateway: IPv4Address?
            public let macAddress: MACAddress?

            // `reference` isn't used concurrently.
            nonisolated(unsafe) private let reference: vmnet_network_ref

            public init(
                reference: vmnet_network_ref,
                ipv4Address: CIDRv4,
                ipv4Gateway: IPv4Address,
                macAddress: MACAddress? = nil
            ) {
                self.ipv4Address = ipv4Address
                self.ipv4Gateway = ipv4Gateway
                self.macAddress = macAddress
                self.reference = reference
            }

            /// Returns the underlying `VZVirtioNetworkDeviceConfiguration`.
            public func device() throws -> VZVirtioNetworkDeviceConfiguration {
                let config = VZVirtioNetworkDeviceConfiguration()
                if let macAddress = self.macAddress {
                    guard let mac = VZMACAddress(string: macAddress.description) else {
                        throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
                    }
                    config.macAddress = mac
                }
                config.attachment = VZVmnetNetworkDeviceAttachment(network: self.reference)
                return config
            }
        }

        /// Creates a new network.
        /// - Parameter subnet: The subnet to use for this network.
        public init(subnet: CIDRv4? = nil) throws {
            var status: vmnet_return_t = .VMNET_FAILURE
            guard let config = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
                throw ContainerizationError(.unsupported, message: "failed to create vmnet config with status \(status)")
            }

            vmnet_network_configuration_disable_dhcp(config)

            if let subnet {
                try Self.configureSubnet(config, subnet: subnet)
            }

            guard let ref = vmnet_network_create(config, &status), status == .VMNET_SUCCESS else {
                throw ContainerizationError(.unsupported, message: "failed to create vmnet network with status \(status)")
            }

            let cidr = try Self.getSubnet(ref)

            self.allocator = try .init(cidr: cidr)
            self.subnet = cidr
            self.reference = ref
        }

        /// Returns a new interface for use with a container.
        /// - Parameter id: The container ID.
        public mutating func create(_ id: String) throws -> Containerization.Interface? {
            let ipv4Address = try allocator.allocate(id)
            return Self.Interface(
                reference: self.reference,
                ipv4Address: ipv4Address,
                ipv4Gateway: self.ipv4Gateway,
            )
        }

        /// Performs cleanup of an interface.
        /// - Parameter id: The container ID.
        public mutating func release(_ id: String) throws {
            try allocator.release(id)
        }

        private static func getSubnet(_ ref: vmnet_network_ref) throws -> CIDRv4 {
            var subnet = in_addr()
            var mask = in_addr()
            vmnet_network_get_ipv4_subnet(ref, &subnet, &mask)

            let sa = UInt32(bigEndian: subnet.s_addr)
            let mv = UInt32(bigEndian: mask.s_addr)

            let lower = IPv4Address(sa & mv)
            let upper = IPv4Address(lower.value + ~mv)

            return try CIDRv4(lower: lower, upper: upper)
        }

        private static func configureSubnet(_ config: vmnet_network_configuration_ref, subnet: CIDRv4) throws {
            let gateway = subnet.gateway

            var ga = in_addr()
            inet_pton(AF_INET, gateway.description, &ga)

            let mask = IPv4Address(subnet.prefix.prefixMask32)
            var ma = in_addr()
            inet_pton(AF_INET, mask.description, &ma)

            guard vmnet_network_configuration_set_ipv4_subnet(config, &ga, &ma) == .VMNET_SUCCESS else {
                throw ContainerizationError(.internalError, message: "failed to set subnet \(subnet) for network")
            }
        }
    }

    /// Create a new manager with the provided kernel, initfs mount, image store
    /// and optional network implementation. This will use a Virtualization.framework
    /// backed VMM implicitly.
    public init(
        kernel: Kernel,
        initfs: Mount,
        imageStore: ImageStore,
        network: Network? = nil,
        rosetta: Bool = false,
        nestedVirtualization: Bool = false
    ) throws {
        self.imageStore = imageStore
        self.network = network
        try Self.createRootDirectory(path: self.imageStore.path)
        self.vmm = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initfs,
            rosetta: rosetta,
            nestedVirtualization: nestedVirtualization
        )
    }

    /// Create a new manager with the provided kernel, initfs mount, root state
    /// directory and optional network implementation. This will use a Virtualization.framework
    /// backed VMM implicitly.
    public init(
        kernel: Kernel,
        initfs: Mount,
        root: URL? = nil,
        network: Network? = nil,
        rosetta: Bool = false,
        nestedVirtualization: Bool = false
    ) throws {
        if let root {
            self.imageStore = try ImageStore(path: root)
        } else {
            self.imageStore = ImageStore.default
        }
        self.network = network
        try Self.createRootDirectory(path: self.imageStore.path)
        self.vmm = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initfs,
            rosetta: rosetta,
            nestedVirtualization: nestedVirtualization
        )
    }

    /// Create a new manager with the provided kernel, initfs reference, image store
    /// and optional network implementation. This will use a Virtualization.framework
    /// backed VMM implicitly.
    public init(
        kernel: Kernel,
        initfsReference: String,
        imageStore: ImageStore,
        network: Network? = nil,
        rosetta: Bool = false,
        nestedVirtualization: Bool = false
    ) async throws {
        self.imageStore = imageStore
        self.network = network
        try Self.createRootDirectory(path: self.imageStore.path)

        let initPath = self.imageStore.path.appendingPathComponent("initfs.ext4")
        let initImage = try await self.imageStore.getInitImage(reference: initfsReference)
        let initfs = try await {
            do {
                return try await initImage.initBlock(at: initPath, for: .linuxArm)
            } catch let err as ContainerizationError {
                guard err.code == .exists else {
                    throw err
                }
                return .block(
                    format: "ext4",
                    source: initPath.absolutePath(),
                    destination: "/",
                    options: ["ro"]
                )
            }
        }()

        self.vmm = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initfs,
            rosetta: rosetta,
            nestedVirtualization: nestedVirtualization
        )
    }

    /// Create a new manager with the provided kernel and image reference for the initfs.
    /// This will use a Virtualization.framework backed VMM implicitly.
    public init(
        kernel: Kernel,
        initfsReference: String,
        root: URL? = nil,
        network: Network? = nil,
        rosetta: Bool = false,
        nestedVirtualization: Bool = false
    ) async throws {
        if let root {
            self.imageStore = try ImageStore(path: root)
        } else {
            self.imageStore = ImageStore.default
        }
        self.network = network
        try Self.createRootDirectory(path: self.imageStore.path)

        let initPath = self.imageStore.path.appendingPathComponent("initfs.ext4")
        let initImage = try await self.imageStore.getInitImage(reference: initfsReference)
        let initfs = try await {
            do {
                return try await initImage.initBlock(at: initPath, for: .linuxArm)
            } catch let err as ContainerizationError {
                guard err.code == .exists else {
                    throw err
                }
                return .block(
                    format: "ext4",
                    source: initPath.absolutePath(),
                    destination: "/",
                    options: ["ro"]
                )
            }
        }()

        self.vmm = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initfs,
            rosetta: rosetta,
            nestedVirtualization: nestedVirtualization
        )
    }

    /// Create a new manager with the provided vmm and network.
    public init(
        vmm: any VirtualMachineManager,
        network: Network? = nil
    ) throws {
        self.imageStore = ImageStore.default
        try Self.createRootDirectory(path: self.imageStore.path)
        self.network = network
        self.vmm = vmm
    }

    private static func createRootDirectory(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.appendingPathComponent("containers"),
            withIntermediateDirectories: true
        )
    }

    /// Returns a new container from the provided image reference.
    /// - Parameters:
    ///   - id: The container ID.
    ///   - reference: The image reference.
    ///   - rootfsSizeInBytes: The size of the root filesystem in bytes. Defaults to 8 GiB.
    ///   - readOnly: Whether to mount the root filesystem as read-only.
    public mutating func create(
        _ id: String,
        reference: String,
        rootfsSizeInBytes: UInt64 = 8.gib(),
        readOnly: Bool = false,
        configuration: (inout LinuxContainer.Configuration) throws -> Void
    ) async throws -> LinuxContainer {
        let image = try await imageStore.get(reference: reference, pull: true)
        return try await create(
            id,
            image: image,
            rootfsSizeInBytes: rootfsSizeInBytes,
            readOnly: readOnly,
            configuration: configuration
        )
    }

    /// Returns a new container from the provided image.
    /// - Parameters:
    ///   - id: The container ID.
    ///   - image: The image.
    ///   - rootfsSizeInBytes: The size of the root filesystem in bytes. Defaults to 8 GiB.
    ///   - readOnly: Whether to mount the root filesystem as read-only.
    public mutating func create(
        _ id: String,
        image: Image,
        rootfsSizeInBytes: UInt64 = 8.gib(),
        readOnly: Bool = false,
        configuration: (inout LinuxContainer.Configuration) throws -> Void
    ) async throws -> LinuxContainer {
        let path = try createContainerRoot(id)

        var rootfs = try await unpack(
            image: image,
            destination: path.appendingPathComponent("rootfs.ext4"),
            size: rootfsSizeInBytes
        )
        if readOnly {
            rootfs.options.append("ro")
        }
        return try await create(
            id,
            image: image,
            rootfs: rootfs,
            configuration: configuration
        )
    }

    /// Returns a new container from the provided image and root filesystem mount.
    /// - Parameters:
    ///   - id: The container ID.
    ///   - image: The image.
    ///   - rootfs: The root filesystem mount pointing to an existing block file.
    public mutating func create(
        _ id: String,
        image: Image,
        rootfs: Mount,
        configuration: (inout LinuxContainer.Configuration) throws -> Void
    ) async throws -> LinuxContainer {
        let imageConfig = try await image.config(for: .current).config
        return try LinuxContainer(
            id,
            rootfs: rootfs,
            vmm: self.vmm
        ) { config in
            if let imageConfig {
                config.process = .init(from: imageConfig)
            }
            if let interface = try self.network?.create(id) {
                config.interfaces = [interface]
                // FIXME: throw instead of crash here if we can't unwrap?
                config.dns = .init(nameservers: [interface.ipv4Gateway!.description])
            }
            config.bootLog = BootLog.file(path: self.containerRoot.appendingPathComponent(id).appendingPathComponent("bootlog.log"))
            try configuration(&config)
        }
    }

    /// Performs the cleanup of a container.
    /// - Parameter id: The container ID.
    public mutating func delete(_ id: String) throws {
        try self.network?.release(id)
        let path = containerRoot.appendingPathComponent(id)
        try FileManager.default.removeItem(at: path)
    }

    private func createContainerRoot(_ id: String) throws -> URL {
        let path = containerRoot.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        return path
    }

    private func unpack(image: Image, destination: URL, size: UInt64) async throws -> Mount {
        do {
            let unpacker = EXT4Unpacker(blockSizeInBytes: size)
            return try await unpacker.unpack(image, for: .current, at: destination)
        } catch let err as ContainerizationError {
            if err.code == .exists {
                return .block(
                    format: "ext4",
                    source: destination.absolutePath(),
                    destination: "/",
                    options: []
                )
            }
            throw err
        }
    }
}

extension CIDRv4 {
    /// The gateway address of the network.
    public var gateway: IPv4Address {
        IPv4Address(self.lower.value + 1)
    }
}

#endif
