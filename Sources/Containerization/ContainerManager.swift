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
import ContainerizationEXT4
import ContainerizationOCI
import ContainerizationOS
import Foundation
import ContainerizationExtras
import SystemPackage
import Virtualization

/// A manager for creating and running containers.
/// Supports container networking options.
public struct ContainerManager: Sendable {
    public let imageStore: ImageStore
    private let vmm: VirtualMachineManager
    private var network: Network?

    private var containerRoot: URL {
        self.imageStore.path.appendingPathComponent("containers")
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
    ///   - writableLayerSizeInBytes: Optional size for a separate writable layer. When provided,
    ///     the rootfs becomes read-only and an overlayfs is used with a separate writable layer of this size.
    ///   - readOnly: Whether to mount the root filesystem as read-only.
    ///   - networking: Whether to create a network interface for this container. Defaults to `true`.
    ///     When `false`, no network resources are allocated and `releaseNetwork`/`delete` remain safe to call.
    public mutating func create(
        _ id: String,
        reference: String,
        rootfsSizeInBytes: UInt64 = 8.gib(),
        writableLayerSizeInBytes: UInt64? = nil,
        readOnly: Bool = false,
        networking: Bool = true,
        configuration: (inout LinuxContainer.Configuration) throws -> Void
    ) async throws -> LinuxContainer {
        let image = try await imageStore.get(reference: reference, pull: true)
        return try await create(
            id,
            image: image,
            rootfsSizeInBytes: rootfsSizeInBytes,
            writableLayerSizeInBytes: writableLayerSizeInBytes,
            readOnly: readOnly,
            networking: networking,
            configuration: configuration
        )
    }

    /// Returns a new container from the provided image.
    /// - Parameters:
    ///   - id: The container ID.
    ///   - image: The image.
    ///   - rootfsSizeInBytes: The size of the root filesystem in bytes. Defaults to 8 GiB.
    ///   - writableLayerSizeInBytes: Optional size for a separate writable layer. When provided,
    ///     the rootfs becomes read-only and an overlayfs is used with a separate writable layer of this size.
    ///   - readOnly: Whether to mount the root filesystem as read-only.
    ///   - networking: Whether to create a network interface for this container. Defaults to `true`.
    ///     When `false`, no network resources are allocated and `releaseNetwork`/`delete` remain safe to call.
    public mutating func create(
        _ id: String,
        image: Image,
        rootfsSizeInBytes: UInt64 = 8.gib(),
        writableLayerSizeInBytes: UInt64? = nil,
        readOnly: Bool = false,
        networking: Bool = true,
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

        // Create writable layer if size is specified.
        var writableLayer: Mount? = nil
        if let writableLayerSize = writableLayerSizeInBytes {
            writableLayer = try createEmptyFilesystem(
                at: path.appendingPathComponent("writable.ext4"),
                size: writableLayerSize
            )
        }

        return try await create(
            id,
            image: image,
            rootfs: rootfs,
            writableLayer: writableLayer,
            networking: networking,
            configuration: configuration
        )
    }

    /// Returns a new container from the provided image and root filesystem mount.
    /// - Parameters:
    ///   - id: The container ID.
    ///   - image: The image.
    ///   - rootfs: The root filesystem mount pointing to an existing block file.
    ///     The `destination` field is ignored as mounting is handled internally.
    ///   - writableLayer: Optional writable layer mount. When provided, an overlayfs is used with
    ///     rootfs as the lower layer and this as the upper layer.
    ///     The `destination` field is ignored as mounting is handled internally.
    ///   - networking: Whether to create a network interface for this container. Defaults to `true`.
    ///     When `false`, no network resources are allocated and `releaseNetwork`/`delete` remain safe to call.
    public mutating func create(
        _ id: String,
        image: Image,
        rootfs: Mount,
        writableLayer: Mount? = nil,
        networking: Bool = true,
        configuration: (inout LinuxContainer.Configuration) throws -> Void
    ) async throws -> LinuxContainer {
        let imageConfig = try await image.config(for: .current).config
        return try LinuxContainer(
            id,
            rootfs: rootfs,
            writableLayer: writableLayer,
            vmm: self.vmm
        ) { config in
            if let imageConfig {
                config.process = .init(from: imageConfig)
            }
            if networking, let interface = try self.network?.create(id) {
                config.interfaces = [interface]
                guard let gateway = interface.ipv4Gateway else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "missing ipv4 gateway for container \(id)"
                    )
                }
                config.dns = .init(nameservers: [gateway.description])
            }
            config.bootLog = BootLog.file(path: self.containerRoot.appendingPathComponent(id).appendingPathComponent("bootlog.log"))
            try configuration(&config)
        }
    }

    /// Releases network resources for a container.
    ///
    /// - Parameter id: The container ID.
    public mutating func releaseNetwork(_ id: String) throws {
        try self.network?.release(id)
    }

    /// Releases network resources and removes all files for a container.
    /// - Parameter id: The container ID.
    public mutating func delete(_ id: String) throws {
        try self.releaseNetwork(id)
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

    private func createEmptyFilesystem(at destination: URL, size: UInt64) throws -> Mount {
        let path = destination.absolutePath()
        guard !FileManager.default.fileExists(atPath: path) else {
            throw ContainerizationError(.exists, message: "filesystem already exists at \(path)")
        }
        let filesystem = try EXT4.Formatter(FilePath(path), minDiskSize: size)
        try filesystem.close()
        return .block(
            format: "ext4",
            source: path,
            destination: "/",
            options: []
        )
    }
}

extension CIDRv4 {
    /// The gateway address of the network.
    public var gateway: IPv4Address {
        IPv4Address(self.lower.value + 1)
    }
}

#endif
