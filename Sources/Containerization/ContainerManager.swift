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

import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation

/// A type that manages containers and their resources within a root directory.
public struct ContainerManager: Sendable {
    public let imageStore: ImageStore
    private let vmm: VirtualMachineManager

    var containerRoot: URL {
        self.imageStore.path.appendingPathComponent("containers")
    }

    /// Create a new manager with the provided kernel and initfs mount.
    public init(
        kernel: Kernel,
        initfs: Mount,
    ) throws {
        self.imageStore = try ImageStore.default
        try Self.createRootDirectory(path: self.imageStore.path)
        self.vmm = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initfs,
            bootlog: self.imageStore.path.appendingPathComponent("bootlog.log").absolutePath()
        )
        try Self.createRootDirectory(path: self.imageStore.path)
    }

    /// Create a new manager with the provided kernel and image reference for the initfs.
    public init(
        kernel: Kernel,
        initfsReference: String
    ) async throws {
        self.imageStore = try ImageStore.default
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
            bootlog: self.imageStore.path.appendingPathComponent("bootlog.log").absolutePath()
        )
    }

    private static func createRootDirectory(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.appendingPathComponent("containers"),
            withIntermediateDirectories: true
        )
    }

    /// Create a new container from the provided image reference.
    public func create(
        _ id: String,
        reference: String,
        rootfsSizeInBytes: UInt64 = 8.gib()
    ) async throws -> LinuxContainer {
        let image = try await imageStore.get(reference: reference, pull: true)
        return try await create(id, image: image, rootfsSizeInBytes: rootfsSizeInBytes)
    }

    /// Create a new container from the provided image.
    public func create(
        _ id: String,
        image: Image,
        rootfsSizeInBytes: UInt64 = 8.gib()
    ) async throws -> LinuxContainer {
        let path = try createContainerRoot(id)

        let rootfs = try await unpack(
            image: image,
            destination: path.appendingPathComponent("rootfs.ext4"),
            size: rootfsSizeInBytes
        )
        return try await create(id, image: image, rootfs: rootfs)
    }

    /// Create a new container from the provided image config but an existing rootfs.
    public func create(
        _ id: String,
        image: Image,
        rootfs: Mount
    ) async throws -> LinuxContainer {
        let config = try await image.config(for: .current).config
        let container = LinuxContainer(
            id,
            rootfs: rootfs,
            vmm: self.vmm
        )
        if let config {
            container.setProcessConfig(from: config)
        }
        return container
    }

    /// Get an existing container from path.
    public func get(_ id: String, image: Image) async throws -> LinuxContainer {
        let path = containerRoot.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: path.absolutePath()) else {
            throw ContainerizationError(.notFound, message: "\(id) does not exist")
        }

        let rootfs: Mount = .block(
            format: "ext4",
            source: path.appendingPathComponent("rootfs.ext4").absolutePath(),
            destination: "/",
            options: []
        )

        let config = try await image.config(for: .current).config
        let container = LinuxContainer(
            id,
            rootfs: rootfs,
            vmm: self.vmm
        )
        if let config {
            container.setProcessConfig(from: config)
        }
        return container
    }

    /// Delete the container's directory by id.
    public func delete(_ id: String) throws {
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

#endif
