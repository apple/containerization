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
import ContainerizationExtras
import ContainerizationOCI
import Foundation

extension ImageStore {
    /// Exports the specified images and their associated layers to an OCI Image Layout directory.
    /// This function saves the images identified by the `references` array, including their
    /// manifests and layer blobs, into a directory structure compliant with the OCI Image Layout specification at the given `out` URL.
    ///
    /// - Parameters:
    ///   - references: A list image references that exists in the `ImageStore` that are to be saved in the OCI Image Layout format.
    ///   - out: A URL to a directory on disk at which the OCI Image Layout structure will be created.
    ///   - platform: An optional parameter to indicate the platform to be saved for the images.
    ///               Defaults to `nil` signifying that layers for all supported platforms by the images will be saved.
    ///
    public func save(references: [String], out: URL, platform: Platform? = nil) async throws {
        let matcher = createPlatformMatcher(for: platform)
        let fileManager = FileManager.default
        let tempDir = fileManager.uniqueTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        var toSave: [Image] = []
        for reference in references {
            let image = try await self.get(reference: reference)
            let allowedMediaTypes = [MediaTypes.dockerManifestList, MediaTypes.index]
            guard allowedMediaTypes.contains(image.mediaType) else {
                throw ContainerizationError(.internalError, message: "cannot save image \(image.reference) with Index media type \(image.mediaType)")
            }
            toSave.append(image)
        }
        let client = try LocalOCILayoutClient(root: out)
        var saved: [Descriptor] = []

        for image in toSave {
            let ref = try Reference.parse(image.reference)
            let name = ref.path
            guard let tag = ref.tag ?? ref.digest else {
                throw ContainerizationError(.invalidArgument, message: "invalid tag/digest for image reference \(image.reference)")
            }
            let operation = ExportOperation(name: name, tag: tag, contentStore: self.contentStore, client: client, progress: nil)
            var descriptor = try await operation.export(index: image.descriptor, platforms: matcher)
            client.setImageReferenceAnnotation(descriptor: &descriptor, reference: image.reference)
            saved.append(descriptor)
        }
        try client.createOCILayoutStructure(directory: out, manifests: saved)
    }

    /// Imports one or more images and their associated layers from an OCI Image Layout directory.
    ///
    /// - Parameters:
    ///   - directory: A URL to a directory on disk at that follows the OCI Image Layout structure.
    ///   - progress: An optional handler over which progress update events about the load operation can be received.
    /// - Returns: The list of images that were loaded into the `ImageStore`.
    ///
    public func load(from directory: URL, progress: ProgressHandler? = nil) async throws -> [Image] {
        let client = try LocalOCILayoutClient(root: directory)
        let index = try client.loadIndexFromOCILayout(directory: directory)
        let matcher = createPlatformMatcher(for: nil)

        var loaded: [Image.Description] = []
        let (id, tempDir) = try await self.contentStore.newIngestSession()
        do {
            for descriptor in index.manifests {
                let reference = client.getImageReferencefromDescriptor(descriptor: descriptor)
                let ref = try Reference.parse(reference)
                let name = ref.path
                let operation = ImportOperation(name: name, contentStore: self.contentStore, client: client, ingestDir: tempDir, progress: progress)
                let indexDesc = try await operation.import(root: descriptor, matcher: matcher)
                loaded.append(Image.Description(reference: reference, descriptor: indexDesc))
            }

            let loadedImages = loaded
            let importedImages = try await self.lock.withLock { lock in
                var images: [Image] = []
                try await self.contentStore.completeIngestSession(id)
                for description in loadedImages {
                    let img = try await self._create(description: description, lock: lock)
                    images.append(img)
                }
                return images
            }
            guard importedImages.count > 0 else {
                throw ContainerizationError(.internalError, message: "failed to import image")
            }
            return importedImages
        } catch {
            try? await self.contentStore.cancelIngestSession(id)
            throw error
        }
    }
}
