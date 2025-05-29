//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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

import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation

#if os(macOS)

import Crypto

extension String {
    fileprivate func hash() throws -> String {
        guard let data = self.data(using: .utf8) else {
            fatalError("\(self) could not be converted to Data")
        }
        return String(SHA256.hash(data: data).encoded.prefix(36))
    }
}

#endif

public final class ContainerStore: Sendable {
    private static let kernelImageReference: String = "ghcr.io/apple-uat/kernel/linux:v6.1.68-1"
    private static let initImage = "vminit:latest"

    private let content: ContentStore
    private let image: ImageStore
    private let root: URL

    public let kernel: Kernel

    public init(root: URL, kernel: Kernel?) async throws {
        self.root = root
        let content = try LocalContentStore(
            path: root.appendingPathComponent("content")
        )
        self.content = content
        self.image = try ImageStore(
            path: root,
            contentStore: content
        )
        if let kernel {
            self.kernel = kernel
        } else {
            self.kernel = try await Self.loadKernel(store: self.image)
        }
    }

    private static func loadKernel(store: ImageStore) async throws -> Kernel {
        let kernelImage = try await store.getKernel(
            reference: Self.kernelImageReference
        )
        return try await kernelImage.kernel(for: .linuxArm)
    }

    public func fetch(reference: String) async throws -> Containerization.Image {
        do {
            return try await self.image.get(reference: reference)
        } catch let error as ContainerizationError {
            if error.code == .notFound {
                return try await self.image.pull(reference: reference)
            }
            throw error
        }
    }

    static func binPath(name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("bin")
            .appendingPathComponent(name)
    }

    public func create(id: String, reference: String, fsSizeInBytes: UInt64) async throws -> LinuxContainer {
        let initImage = try await image.getInitImage(reference: Self.initImage)
        let initfs = try await {
            let p = Self.binPath(name: "init.block")
            do {
                return try await initImage.initBlock(at: p, for: .linuxArm)
            } catch let err as ContainerizationError {
                guard err.code == .exists else {
                    throw err
                }
                return .block(
                    format: "ext4",
                    source: p.absolutePath(),
                    destination: "/",
                    options: ["ro"]
                )
            }
        }()

        let blockName = try reference.hash() + ".ext4"
        let image = try await fetch(reference: reference)
        let imageConfig = try await image.config(for: .current).config

        let imageBlock: Containerization.Mount = try await {
            let source = self.root.appendingPathComponent(blockName)
            do {
                return try await image.unpack(
                    for: .current,
                    at: source,
                    blockSizeInBytes: fsSizeInBytes
                )
            } catch let err as ContainerizationError {
                if err.code == .exists {
                    return .block(
                        format: "ext4",
                        source: source.absolutePath(),
                        destination: "/",
                        options: []
                    )
                }
                throw err
            } catch {
                throw error
            }
        }()

        let vmm = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initfs,
            bootlog: "cctl.log"
        )

        let linuxContainer = LinuxContainer(
            id,
            rootfs: imageBlock,
            vmm: vmm
        )
        if let imageConfig {
            linuxContainer.setProcessConfig(from: imageConfig)
        }
        return linuxContainer
    }
}
