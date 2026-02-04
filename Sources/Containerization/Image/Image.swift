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

import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation

/// Type representing an OCI container image.
public struct Image: Sendable {
    private let contentStore: ContentStore
    /// The description for the image that comprises of its name and a reference to its root descriptor.
    public let description: Description

    /// A description of the OCI image.
    public struct Description: Sendable {
        /// The string reference of the image.
        public let reference: String
        /// The descriptor identifying the image.
        public let descriptor: Descriptor
        /// The digest for the image.
        public var digest: String { descriptor.digest }
        /// The media type of the image.
        public var mediaType: String { descriptor.mediaType }

        public init(reference: String, descriptor: Descriptor) {
            self.reference = reference
            self.descriptor = descriptor
        }
    }

    /// The descriptor for the image.
    public var descriptor: Descriptor { description.descriptor }
    /// The digest of the image.
    public var digest: String { description.digest }
    /// The media type of the image.
    public var mediaType: String { description.mediaType }
    /// The string reference for the image.
    public var reference: String { description.reference }

    public init(description: Description, contentStore: ContentStore) {
        self.description = description
        self.contentStore = contentStore
    }

    /// Returns the underlying OCI index for the image.
    public func index() async throws -> Index {
        guard let content: Content = try await contentStore.get(digest: digest) else {
            throw ContainerizationError(.notFound, message: "content with digest \(digest)")
        }
        return try content.decode()
    }

    /// Returns the manifest for the specified platform.
    public func manifest(for platform: Platform) async throws -> Manifest {
        let index = try await self.index()
        let desc = index.manifests.first { desc in
            desc.platform == platform
        }
        guard let desc else {
            throw ContainerizationError(.unsupported, message: "platform \(platform.description)")
        }
        guard let content: Content = try await contentStore.get(digest: desc.digest) else {
            throw ContainerizationError(.notFound, message: "content with digest \(digest)")
        }
        return try content.decode()
    }

    /// Returns the descriptor for the given platform. If it does not exist
    /// will throw a ContainerizationError with the code set to .invalidArgument.
    public func descriptor(for platform: Platform) async throws -> Descriptor {
        let index = try await self.index()
        let desc = index.manifests.first { $0.platform == platform }
        guard let desc else {
            throw ContainerizationError(.invalidArgument, message: "unsupported platform \(platform)")
        }
        return desc
    }

    /// Returns the OCI config for the specified platform.
    public func config(for platform: Platform) async throws -> ContainerizationOCI.Image {
        let manifest = try await self.manifest(for: platform)
        let desc = manifest.config
        guard let content: Content = try await contentStore.get(digest: desc.digest) else {
            throw ContainerizationError(.notFound, message: "content with digest \(digest)")
        }
        return try content.decode()
    }

    /// Returns a list of digests to all the referenced OCI objects.
    public func referencedDigests() async throws -> [String] {
        var referenced: [String] = [self.digest.trimmingDigestPrefix]
        let index = try await self.index()
        for manifest in index.manifests {
            referenced.append(manifest.digest.trimmingDigestPrefix)
            guard let m: Manifest = try? await contentStore.get(digest: manifest.digest) else {
                // If the requested digest does not exist or is not a manifest. Skip.
                // Its safe to skip processing this digest as it wont have any child layers.
                continue
            }
            let descs = m.layers + [m.config]
            referenced.append(contentsOf: descs.map { $0.digest.trimmingDigestPrefix })
        }
        return referenced
    }

    /// Returns a reference to the content blob for the image. The specified digest must be referenced by the image in one of its layers.
    public func getContent(digest: String) async throws -> Content {
        guard try await self.referencedDigests().contains(digest.trimmingDigestPrefix) else {
            throw ContainerizationError(.internalError, message: "image \(self.reference) does not reference digest \(digest)")
        }
        guard let content: Content = try await contentStore.get(digest: digest) else {
            throw ContainerizationError(.notFound, message: "content with digest \(digest)")
        }
        return content
    }
}
