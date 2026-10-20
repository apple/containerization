//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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
import ContainerizationExtras
import ContainerizationOCI
import Foundation

extension ImageStore {
    /// Returns the runnable platforms of an image without pulling layers.
    ///
    /// Reads the local index when the reference exists, else the remote index or manifest.
    public func platforms(reference: String, insecure: Bool = false, auth: Authentication? = nil) async throws -> [Platform] {
        if let image = try await self.getOrNil(reference: reference) {
            return try await image.index().runnablePlatforms
        }

        let client = try RegistryClient(reference: reference, insecure: insecure, auth: auth, tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration())
        let ref = try Reference.parse(reference)
        guard let tag = ref.tag ?? ref.digest else {
            throw ContainerizationError(.invalidArgument, message: "invalid tag/digest for image reference \(reference)")
        }

        let root = try await client.resolve(name: ref.path, tag: tag)
        return try await Self.platforms(root: root, name: ref.path, client: client)
    }

    static func platforms(root: Descriptor, name: String, client: ContentClient) async throws -> [Platform] {
        switch root.mediaType {
        case MediaTypes.index, MediaTypes.dockerManifestList:
            let index: Index = try await client.fetch(name: name, descriptor: root)
            return index.runnablePlatforms
        case MediaTypes.imageManifest, MediaTypes.dockerManifest:
            let manifest: Manifest = try await client.fetch(name: name, descriptor: root)
            let config: ContainerizationOCI.Image = try await client.fetch(name: name, descriptor: manifest.config)
            return [Platform(arch: config.architecture, os: config.os, osFeatures: config.osFeatures, variant: config.variant)]
        default:
            throw ContainerizationError(.unsupported, message: "unsupported media type \(root.mediaType) for \(root.digest)")
        }
    }
}
