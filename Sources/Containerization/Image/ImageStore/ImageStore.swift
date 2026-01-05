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

/// An ImageStore handles the mappings between an image's
/// reference and the underlying descriptor inside of a content store.
public actor ImageStore: Sendable {
    /// The ImageStore path it was created with.
    public nonisolated let path: URL

    private let referenceManager: ReferenceManager
    internal let contentStore: ContentStore
    internal let lock: AsyncLock = AsyncLock()

    public init(path: URL, contentStore: ContentStore? = nil) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        if let contentStore {
            self.contentStore = contentStore
        } else {
            self.contentStore = try LocalContentStore(path: path.appendingPathComponent("content"))
        }

        self.path = path
        self.referenceManager = try ReferenceManager(path: path)
    }

    /// Return the default image store for the current user.
    public static let `default`: ImageStore = {
        do {
            let root = try defaultRoot()
            return try ImageStore(path: root)
        } catch {
            fatalError("unable to initialize default ImageStore \(error)")
        }
    }()

    private static func defaultRoot() throws -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        guard let root else {
            throw ContainerizationError(.notFound, message: "unable to get Application Support directory for current user")
        }
        return root.appendingPathComponent("com.apple.containerization")

    }
}

extension ImageStore {
    /// Get an image from the `ImageStore`.
    ///
    /// - Parameters:
    ///   - reference: Name of the image.
    ///   - pull: Pull the image if it is not found.
    ///
    /// - Returns: A `Containerization.Image`  object whose `reference` matches the given string.
    ///   This  method throws a `ContainerizationError(code: .notFound)` if the provided reference does not exist in the `ImageStore`.
    public func get(reference: String, pull: Bool = false) async throws -> Image {
        do {
            let desc = try await self.referenceManager.get(reference: reference)
            return Image(description: desc, contentStore: self.contentStore)
        } catch let error as ContainerizationError {
            if error.code == .notFound && pull {
                return try await self.pull(reference: reference)
            }
            throw error
        }
    }

    /// Get a list of all images in the `ImageStore`.
    ///
    /// - Returns: A `[Containerization.Image]` for all the images in the `ImageStore`.
    public func list() async throws -> [Image] {
        try await self.referenceManager.list().map { desc in
            Image(description: desc, contentStore: self.contentStore)
        }
    }

    /// Create a new image in the `ImageStore`.
    ///
    /// - Parameters:
    ///   - description: The underlying `Image.Description` that contains information about the reference and index descriptor for the image to be created.
    ///
    /// - Note: It is assumed that the underlying manifests and blob layers for the image already exists in the `ContentStore` that the `ImageStore` was initialized with. This method is invoked when the `pull(...)` , `load(...)` and `tag(...)` methods are used.
    /// - Returns: A `Containerization.Image`
    @discardableResult
    public func create(description: Image.Description) async throws -> Image {
        try await self.lock.withLock { ctx in
            try await self._create(description: description, lock: ctx)
        }
    }

    @discardableResult
    internal func _create(description: Image.Description, lock: AsyncLock.Context) async throws -> Image {
        try await self.referenceManager.create(description: description)
        return Image(description: description, contentStore: self.contentStore)
    }

    /// Delete an image from the `ImageStore`.
    ///
    /// - Parameters:
    ///   - reference: Name of the image that is to be deleted.
    ///   - performCleanup: Perform a garbage collection on the `ContentStore`, removing all unreferenced image layers and manifests,
    public func delete(reference: String, performCleanup: Bool = false) async throws {
        try await self.lock.withLock { lockCtx in
            try await self.referenceManager.delete(reference: reference)
            if performCleanup {
                try await self._cleanupOrphanedBlobs(lockCtx)
            }
        }
    }

    /// Clean up orphaned blobs that are no longer referenced by any image.
    ///
    /// - Returns: Returns a tuple of `(deleted, freed)`.
    ///   `deleted` :  A  list of the names of the content items that were deleted from the `ContentStore`,
    ///   `freed` : The total size of the items that were deleted.
    @discardableResult
    public func cleanupOrphanedBlobs() async throws -> (deleted: [String], freed: UInt64) {
        try await self.lock.withLock { lockCtx in
            try await self._cleanupOrphanedBlobs(lockCtx)
        }
    }

    /// Calculate the size of orphaned blobs without deleting them.
    ///
    /// - Returns: The total size in bytes of blobs that are not referenced by any image.
    public func calculateOrphanedBlobsSize() async throws -> UInt64 {
        try await self.lock.withLock { lockCtx in
            try await self._calculateOrphanedBlobsSize(lockCtx)
        }
    }

    @discardableResult
    private func _cleanupOrphanedBlobs(_ lock: AsyncLock.Context) async throws -> (deleted: [String], freed: UInt64) {
        let images = try await self.list()
        var referenced: [String] = []
        for image in images {
            try await referenced.append(contentsOf: image.referencedDigests().uniqued())
        }
        let (deleted, size) = try await self.contentStore.delete(keeping: referenced)
        return (deleted, size)
    }

    private func _calculateOrphanedBlobsSize(_ lock: AsyncLock.Context) async throws -> UInt64 {
        let images = try await self.list()
        var referenced: [String] = []
        for image in images {
            try await referenced.append(contentsOf: image.referencedDigests().uniqued())
        }

        // Calculate size of blobs not in the referenced list
        let referencedSet = Set(referenced.map { $0.trimmingDigestPrefix })
        let blobsPath = self.path.appendingPathComponent("content/blobs/sha256")

        let fileManager = FileManager.default
        let allBlobs = try fileManager.contentsOfDirectory(
            at: blobsPath,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var orphanedSize: UInt64 = 0
        for blobURL in allBlobs {
            let digest = blobURL.lastPathComponent
            if !referencedSet.contains(digest) {
                if let resourceValues = try? blobURL.resourceValues(forKeys: [.fileSizeKey]),
                    let size = resourceValues.fileSize
                {
                    orphanedSize += UInt64(size)
                }
            }
        }

        return orphanedSize
    }

    /// Tag an existing image such that it can be referenced by another name.
    ///
    /// - Parameters:
    ///   - existing: The reference to an image that already exists in the `ImageStore`.
    ///   - new: The new reference by which the image should also be referenced as.
    /// - Note: The new image created in the `ImageStore` will have the same `Image.Description`
    ///         as that of the image with reference `existing.`
    /// - Returns: A `Containerization.Image` object to the newly created image.
    public func tag(existing: String, new: String) async throws -> Image {
        let old = try await self.get(reference: existing)
        let descriptor = old.descriptor
        do {
            _ = try Reference.parse(new)
        } catch {
            throw ContainerizationError(.invalidArgument, message: "invalid reference \(new), error: \(error)")
        }
        let newDescription = Image.Description(reference: new, descriptor: descriptor)
        return try await self.create(description: newDescription)
    }
}

extension ImageStore {
    /// Pull an image and its associated manifest and blob layers from a remote registry.
    ///
    /// - Parameters:
    ///   - reference: A string that references an image in a remote registry of the form `<host>[:<port>]/repository:<tag>`
    ///                For example: "docker.io/library/alpine:latest".
    ///   - platform: An optional parameter to indicate the platform to be pulled for the image.
    ///               Defaults to `nil` signifying that layers for all supported platforms by the image will be pulled.
    ///   - insecure: A boolean indicating if the connection to the remote registry should be made via plain-text http or not.
    ///               Defaults to false, meaning the connection to the registry will be over https.
    ///   - auth: An object that implements the `Authentication` protocol,
    ///           used to add any credentials to the HTTP requests that are made to the registry.
    ///           Defaults to `nil` meaning no additional credentials are added to any HTTP requests made to the registry.
    ///   - progress: An optional handler over which progress update events about the pull operation can be received.
    ///
    /// - Returns: A `Containerization.Image` object to the newly pulled image.
    public func pull(
        reference: String, platform: Platform? = nil, insecure: Bool = false,
        auth: Authentication? = nil, progress: ProgressHandler? = nil, maxConcurrentDownloads: Int = 3
    ) async throws -> Image {

        let matcher = createPlatformMatcher(for: platform)
        let client = try RegistryClient(reference: reference, insecure: insecure, auth: auth, tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration())

        let ref = try Reference.parse(reference)
        let name = ref.path
        guard let tag = ref.tag ?? ref.digest else {
            throw ContainerizationError(.invalidArgument, message: "invalid tag/digest for image reference \(reference)")
        }

        let rootDescriptor = try await client.resolve(name: name, tag: tag)
        let (id, tempDir) = try await self.contentStore.newIngestSession()
        let operation = ImportOperation(
            name: name, contentStore: self.contentStore, client: client, ingestDir: tempDir, progress: progress, maxConcurrentDownloads: maxConcurrentDownloads)
        do {
            let index = try await operation.import(root: rootDescriptor, matcher: matcher)
            return try await self.lock.withLock { lock in
                try await self.contentStore.completeIngestSession(id)
                let description = Image.Description(reference: reference, descriptor: index)
                let image = try await self._create(description: description, lock: lock)
                return image
            }
        } catch {
            try? await self.contentStore.cancelIngestSession(id)
            throw error
        }
    }

    /// Push an image and its associated manifest and blob layers to a remote registry.
    ///
    /// - Parameters:
    ///   - reference: A string that references an image in the `ImageStore`.  It must be of the form `<host>[:<port>]/repository:<tag>`
    ///                For example: "ghcr.io/foo-bar-baz/image:v1".
    ///   - platform: An optional parameter to indicate the platform to be pushed for the image.
    ///               Defaults to `nil` signifying that layers for all supported platforms by the image will be pushed to the remote registry.
    ///   - insecure: A boolean indicating if the connection to the remote registry should be made via plain-text http or not.
    ///               Defaults to false, meaning the connection to the registry will be over https.
    ///   - auth: An object that implements the `Authentication` protocol,
    ///           used to add any credentials to the HTTP requests that are made to the registry.
    ///           Defaults to `nil` meaning no additional credentials are added to any HTTP requests made to the registry.
    ///   - progress: An optional handler over which progress update events about the push operation can be received.
    ///
    public func push(reference: String, platform: Platform? = nil, insecure: Bool = false, auth: Authentication? = nil, progress: ProgressHandler? = nil) async throws {
        let matcher = createPlatformMatcher(for: platform)
        let img = try await self.get(reference: reference)
        let allowedMediaTypes = [MediaTypes.dockerManifestList, MediaTypes.index]
        guard allowedMediaTypes.contains(img.mediaType) else {
            throw ContainerizationError(.internalError, message: "cannot push image \(reference) with Index media type \(img.mediaType)")
        }
        let ref = try Reference.parse(reference)
        let name = ref.path
        guard let tag = ref.tag ?? ref.digest else {
            throw ContainerizationError(.invalidArgument, message: "invalid tag/digest for image reference \(reference)")
        }
        let client = try RegistryClient(reference: reference, insecure: insecure, auth: auth, tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration())
        let operation = ExportOperation(name: name, tag: tag, contentStore: self.contentStore, client: client, progress: progress)
        try await operation.export(index: img.descriptor, platforms: matcher)
    }
}

extension ImageStore {
    /// Get the image for the init block from the image store.
    /// If the image does not exist locally, pull the image.
    public func getInitImage(reference: String, auth: Authentication? = nil, progress: ProgressHandler? = nil) async throws -> InitImage {
        do {
            let image = try await self.get(reference: reference)
            return InitImage(image: image)
        } catch let error as ContainerizationError {
            if error.code == .notFound {
                let image = try await self.pull(reference: reference, auth: auth, progress: progress)
                return InitImage(image: image)
            }
            throw error
        }
    }
}
