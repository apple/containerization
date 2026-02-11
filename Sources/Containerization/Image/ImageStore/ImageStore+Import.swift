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

//

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

extension ImageStore {
    public struct ImportOperation: Sendable {
        static let decoder = JSONDecoder()

        let client: ContentClient
        let ingestDir: URL
        let contentStore: ContentStore
        let progress: ProgressHandler?
        let name: String
        let maxConcurrentDownloads: Int

        public init(name: String, contentStore: ContentStore, client: ContentClient, ingestDir: URL, progress: ProgressHandler? = nil, maxConcurrentDownloads: Int = 3) {
            self.client = client
            self.ingestDir = ingestDir
            self.contentStore = contentStore
            self.progress = progress
            self.name = name
            self.maxConcurrentDownloads = maxConcurrentDownloads
        }

        /// Pull the required image layers for the provided descriptor and platform(s) into the given directory using the provided client. Returns a descriptor to the Index manifest.
        public func `import`(root: Descriptor, matcher: (ContainerizationOCI.Platform) -> Bool) async throws -> Descriptor {
            var toProcess = [root]
            while !toProcess.isEmpty {
                // Count the total number of blobs and their size
                if let progress {
                    var size: Int64 = 0
                    for desc in toProcess {
                        size += desc.size
                    }
                    await progress([
                        ProgressEvent(event: "add-total-size", value: size),
                        ProgressEvent(event: "add-total-items", value: toProcess.count),
                    ])
                }

                try await self.fetchAll(toProcess)
                let children = try await self.walk(toProcess)
                let filtered = try filterPlatforms(matcher: matcher, children)
                toProcess = filtered.uniqued { $0.digest }
            }

            guard root.mediaType != MediaTypes.dockerManifestList && root.mediaType != MediaTypes.index else {
                return root
            }

            // Create an index for the root descriptor and write it to the content store
            let index = try await self.createIndex(for: root)
            // In cases where the root descriptor pointed to `MediaTypes.imageManifest`
            // Or `MediaTypes.dockerManifest`, it is required that we check the supported platform
            // matches the platforms we were asked to pull. This can be done only after we created
            // the Index.
            let supportedPlatforms = index.manifests.compactMap { $0.platform }
            guard supportedPlatforms.allSatisfy(matcher) else {
                throw ContainerizationError(.unsupported, message: "image \(root.digest) does not support required platforms")
            }
            let writer = try ContentWriter(for: self.ingestDir)
            let result = try writer.create(from: index)
            return Descriptor(
                mediaType: MediaTypes.index,
                digest: result.digest.digestString,
                size: Int64(result.size))
        }

        private func getManifestContent<T: Sendable & Codable>(descriptor: Descriptor) async throws -> T {
            do {
                if let content = try await self.contentStore.get(digest: descriptor.digest.trimmingDigestPrefix) {
                    return try content.decode()
                }
                if let content = try? LocalContent(path: ingestDir.appending(path: descriptor.digest.trimmingDigestPrefix)) {
                    return try content.decode()
                }
                return try await self.client.fetch(name: name, descriptor: descriptor)
            } catch {
                throw ContainerizationError(.internalError, message: "cannot fetch content with digest \(descriptor.digest)", cause: error)
            }
        }

        private func walk(_ descriptors: [Descriptor]) async throws -> [Descriptor] {
            var out: [Descriptor] = []
            for desc in descriptors {
                let mediaType = desc.mediaType
                switch mediaType {
                case MediaTypes.index, MediaTypes.dockerManifestList:
                    let index: Index = try await self.getManifestContent(descriptor: desc)
                    out.append(contentsOf: index.manifests)
                case MediaTypes.imageManifest, MediaTypes.dockerManifest:
                    let manifest: Manifest = try await self.getManifestContent(descriptor: desc)
                    out.append(manifest.config)
                    out.append(contentsOf: manifest.layers)
                default:
                    // TODO: Explicitly handle other content types
                    continue
                }
            }
            return out
        }

        private func fetchAll(_ descriptors: [Descriptor]) async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = descriptors.makeIterator()
                // Start initial batch of concurrent downloads based on maxConcurrentDownloads
                for _ in 0..<self.maxConcurrentDownloads {
                    if let desc = iterator.next() {
                        group.addTask {
                            try await self.fetch(desc)
                        }
                    }
                }
                // As tasks complete, add new ones to maintain concurrency
                for try await _ in group {
                    if let desc = iterator.next() {
                        group.addTask {
                            try await self.fetch(desc)
                        }
                    }
                }
            }
        }

        private func fetch(_ descriptor: Descriptor) async throws {
            if let found = try await self.contentStore.get(digest: descriptor.digest) {
                try FileManager.default.copyItem(at: found.path, to: ingestDir.appendingPathComponent(descriptor.digest.trimmingDigestPrefix))
                await progress?([
                    // Count the size of the blob
                    ProgressEvent(event: "add-size", value: descriptor.size),
                    // Count the number of blobs
                    ProgressEvent(event: "add-items", value: 1),
                ])
                return
            }

            if descriptor.size > 1.mib() {
                try await self.fetchBlob(descriptor)
            } else {
                try await self.fetchData(descriptor)
            }
            // Count the number of blobs
            await progress?([
                ProgressEvent(event: "add-items", value: 1)
            ])
        }

        private func fetchBlob(_ descriptor: Descriptor) async throws {
            let id = UUID().uuidString
            let fm = FileManager.default
            let tempFile = ingestDir.appendingPathComponent(id)
            let (_, digest) = try await client.fetchBlob(name: name, descriptor: descriptor, into: tempFile, progress: progress)
            guard digest.digestString == descriptor.digest else {
                throw ContainerizationError(.internalError, message: "digest mismatch expected \(descriptor.digest), got \(digest.digestString)")
            }
            do {
                try fm.moveItem(at: tempFile, to: ingestDir.appendingPathComponent(digest.encoded))
            } catch let err as NSError {
                guard err.code == NSFileWriteFileExistsError else {
                    throw err
                }
                try fm.removeItem(at: tempFile)
            }
        }

        @discardableResult
        private func fetchData(_ descriptor: Descriptor) async throws -> Data {
            let data = try await client.fetchData(name: name, descriptor: descriptor)
            let writer = try ContentWriter(for: ingestDir)
            let result = try writer.write(data)
            if let progress {
                let size = Int64(result.size)
                await progress([
                    ProgressEvent(event: "add-size", value: size)
                ])
            }
            guard result.digest.digestString == descriptor.digest else {
                throw ContainerizationError(.internalError, message: "digest mismatch expected \(descriptor.digest), got \(result.digest.digestString)")
            }
            return data
        }

        private func createIndex(for root: Descriptor) async throws -> Index {
            switch root.mediaType {
            case MediaTypes.index, MediaTypes.dockerManifestList:
                return try await self.getManifestContent(descriptor: root)
            case MediaTypes.imageManifest, MediaTypes.dockerManifest:
                let supportedPlatforms = try await getSupportedPlatforms(for: root)
                guard supportedPlatforms.count == 1 else {
                    throw ContainerizationError(
                        .internalError,
                        message:
                            "descriptor \(root.mediaType) with digest \(root.digest) does not list any supported platform or supports more than one platform, supported platforms: \(supportedPlatforms)"
                    )
                }
                let platform = supportedPlatforms.first!
                var root = root
                root.platform = platform
                let index = ContainerizationOCI.Index(
                    schemaVersion: 2, manifests: [root],
                    annotations: [
                        // indicate that this is a synthesized index which is not directly user facing
                        AnnotationKeys.containerizationIndexIndirect: "true"
                    ])
                return index
            default:
                throw ContainerizationError(.internalError, message: "failed to create index for descriptor \(root.digest), media type \(root.mediaType)")
            }
        }

        private func getSupportedPlatforms(for root: Descriptor) async throws -> [ContainerizationOCI.Platform] {
            var supportedPlatforms: [ContainerizationOCI.Platform] = []
            var toProcess = [root]
            while !toProcess.isEmpty {
                let children = try await self.walk(toProcess)
                for child in children {
                    if let p = child.platform {
                        supportedPlatforms.append(p)
                        continue
                    }
                    switch child.mediaType {
                    case MediaTypes.imageConfig, MediaTypes.dockerImageConfig:
                        let config: ContainerizationOCI.Image = try await self.getManifestContent(descriptor: child)
                        let p = ContainerizationOCI.Platform(
                            arch: config.architecture, os: config.os, osFeatures: config.osFeatures, variant: config.variant
                        )
                        supportedPlatforms.append(p)
                    default:
                        continue
                    }
                }
                toProcess = children
            }
            return supportedPlatforms
        }

    }
}
