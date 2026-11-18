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

    /// Imports the one image in an OCI Image Layout directory and stores it under `reference`.
    ///
    /// Unlike ``load(from:progress:)``, this ignores the layout's names and takes every blob from the
    /// layout, never from the content store, so an untrusted layout cannot replace another image or
    /// use another image's layers. An image already stored under `reference` is replaced.
    ///
    /// - Parameters:
    ///   - directory: A URL to a directory on disk that follows the OCI Image Layout structure.
    ///   - reference: The name to store the image under.
    ///   - platform: The platform to import. Defaults to `nil`, which imports every platform in the layout.
    ///   - progress: An optional handler over which progress update events about the load operation can be received.
    /// - Returns: The loaded image.
    /// - Throws: A `ContainerizationError` with code `.invalidArgument` if the layout does not hold exactly one image.
    public func load(from directory: URL, as reference: String, platform: Platform? = nil, progress: ProgressHandler? = nil) async throws -> Image {
        let client = try LocalOCILayoutClient(root: directory)
        let manifests = try client.loadIndexFromOCILayout(directory: directory).manifests
        guard manifests.count == 1, let root = manifests.first else {
            throw ContainerizationError(.invalidArgument, message: "OCI layout at \(directory.path) holds \(manifests.count) images, not 1")
        }
        return try await self.load(
            [(root, reference)], from: client, matcher: createPlatformMatcher(for: platform), reusesStoredContent: false, progress: progress
        )[0]
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
        let roots = index.manifests.map { ($0, client.getImageReferencefromDescriptor(descriptor: $0)) }
        let images = try await self.load(roots, from: client, matcher: createPlatformMatcher(for: nil), reusesStoredContent: true, progress: progress)
        guard images.count > 0 else {
            throw ContainerizationError(.internalError, message: "failed to import image")
        }
        return images
    }

    /// Imports each root into one ingest session, then stores each image under its reference.
    private func load(
        _ roots: [(descriptor: Descriptor, reference: String)],
        from client: LocalOCILayoutClient,
        matcher: @Sendable (Platform) -> Bool,
        reusesStoredContent: Bool,
        progress: ProgressHandler?
    ) async throws -> [Image] {
        var loaded: [Image.Description] = []
        let (id, tempDir) = try await self.contentStore.newIngestSession()
        do {
            for root in roots {
                let name = try Reference.parse(root.reference).path
                let operation = ImportOperation(
                    name: name, contentStore: self.contentStore, client: client, ingestDir: tempDir, progress: progress, reusesStoredContent: reusesStoredContent)
                let indexDesc = try await operation.import(root: root.descriptor, matcher: matcher)
                loaded.append(Image.Description(reference: root.reference, descriptor: indexDesc))
            }

            let loadedImages = loaded
            return try await self.lock.withLock { lock in
                var images: [Image] = []
                try await self.contentStore.completeIngestSession(id)
                for description in loadedImages {
                    let img = try await self._create(description: description, lock: lock)
                    images.append(img)
                }
                return images
            }
        } catch {
            try? await self.contentStore.cancelIngestSession(id)
            throw error
        }
    }
}
