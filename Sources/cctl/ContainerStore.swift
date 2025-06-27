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

struct ContainerStore: Sendable {
    private static let initImage = "vminit:latest"

    private let content: ContentStore
    private let image: ImageStore
    private let root: URL

    public let kernel: Kernel
    public let initPath: URL

    public init(root: URL, kernel: Kernel, initPath: URL) async throws {
        self.root = root
        self.kernel = kernel
        self.initPath = initPath

        let content = try LocalContentStore(
            path: root.appendingPathComponent("content")
        )
        self.content = content
        self.image = try ImageStore(
            path: root,
            contentStore: content
        )
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

    public func create(id: String, reference: String, fsSizeInBytes: UInt64) async throws -> LinuxContainer {
        let initImage = try await image.getInitImage(reference: Self.initImage)
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

        let blockName = try reference.hash() + ".ext4"
        let image = try await fetch(reference: reference)
        let imageConfig = try await image.config(for: .current).config

        let imageBlock: Containerization.Mount = try await {
            let source = self.root.appendingPathComponent(blockName)
            do {
                let unpacker = EXT4Unpacker(blockSizeInBytes: fsSizeInBytes)
                return try await unpacker.unpack(image, for: .current, at: source)
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
