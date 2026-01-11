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
import ContainerizationIO
import ContainerizationOCI
import Crypto
import Foundation

extension ImageStore {
    public struct ExportOperation: Sendable {
        let name: String
        let tag: String
        let contentStore: ContentStore
        let client: ContentClient
        let progress: ProgressHandler?

        public init(name: String, tag: String, contentStore: ContentStore, client: ContentClient, progress: ProgressHandler? = nil) {
            self.contentStore = contentStore
            self.client = client
            self.progress = progress
            self.name = name
            self.tag = tag
        }

        @discardableResult
        public func export(index: Descriptor, platforms: (Platform) -> Bool) async throws -> Descriptor {
            var pushQueue: [[Descriptor]] = []
            var current: [Descriptor] = [index]
            while !current.isEmpty {
                let children = try await self.getChildren(descs: current)
                let matches = try filterPlatforms(matcher: platforms, children).uniqued { $0.digest }
                pushQueue.append(matches)
                current = matches
            }
            let localIndexData = try await self.createIndex(from: index, matching: platforms)

            await updatePushProgress(pushQueue: pushQueue, localIndexData: localIndexData)

            // We need to work bottom up when pushing an image.
            // First, the tar blobs / config layers, then, the manifests and so on...
            // When processing a given "level", the requests maybe made in parallel.
            // We need to ensure that the child level has been uploaded fully
            // before uploading the parent level.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for layerGroup in pushQueue.reversed() {
                    for chunk in layerGroup.chunks(ofCount: 8) {
                        for desc in chunk {
                            guard let content = try await self.contentStore.get(digest: desc.digest) else {
                                throw ContainerizationError(.notFound, message: "content with digest \(desc.digest)")
                            }
                            group.addTask {
                                let readStream = try ReadStream(url: content.path)
                                try await self.pushContent(descriptor: desc, stream: readStream)
                            }
                        }
                        try await group.waitForAll()
                    }
                }
            }

            // Lastly, we need to construct and push a new index, since we may
            // have pushed content only for specific platforms.
            let digest = SHA256.hash(data: localIndexData)
            let descriptor = Descriptor(
                mediaType: MediaTypes.index,
                digest: digest.digestString,
                size: Int64(localIndexData.count))
            let stream = ReadStream(data: localIndexData)
            try await self.pushContent(descriptor: descriptor, stream: stream)
            return descriptor
        }

        private func updatePushProgress(pushQueue: [[Descriptor]], localIndexData: Data) async {
            for layerGroup in pushQueue {
                for desc in layerGroup {
                    await progress?([
                        ProgressEvent(event: "add-total-size", value: desc.size),
                        ProgressEvent(event: "add-total-items", value: 1),
                    ])
                }
            }
            await progress?([
                ProgressEvent(event: "add-total-size", value: localIndexData.count),
                ProgressEvent(event: "add-total-items", value: 1),
            ])
        }

        private func createIndex(from index: Descriptor, matching: (Platform) -> Bool) async throws -> Data {
            guard let content = try await self.contentStore.get(digest: index.digest) else {
                throw ContainerizationError(.notFound, message: "content with digest \(index.digest)")
            }
            var idx: Index = try content.decode()
            let manifests = idx.manifests
            var matchedManifests: [Descriptor] = []
            var skippedPlatforms = false
            for manifest in manifests {
                guard let p = manifest.platform else {
                    continue
                }
                if matching(p) {
                    matchedManifests.append(manifest)
                } else {
                    skippedPlatforms = true
                }
            }
            if !skippedPlatforms {
                return try content.data()
            }
            idx.manifests = matchedManifests
            return try JSONEncoder().encode(idx)
        }

        private func pushContent(descriptor: Descriptor, stream: ReadStream) async throws {
            do {
                let generator = {
                    try stream.reset()
                    return stream.stream
                }
                try await client.push(name: name, ref: tag, descriptor: descriptor, streamGenerator: generator, progress: progress)
                await progress?([
                    ProgressEvent(event: "add-size", value: descriptor.size),
                    ProgressEvent(event: "add-items", value: 1),
                ])
            } catch let err as ContainerizationError {
                guard err.code != .exists else {
                    // We reported the total items and size and have to account for them in existing content.
                    await progress?([
                        ProgressEvent(event: "add-size", value: descriptor.size),
                        ProgressEvent(event: "add-items", value: 1),
                    ])
                    return
                }
                throw err
            }
        }

        private func getChildren(descs: [Descriptor]) async throws -> [Descriptor] {
            var out: [Descriptor] = []
            for desc in descs {
                let mediaType = desc.mediaType
                guard let content = try await self.contentStore.get(digest: desc.digest) else {
                    throw ContainerizationError(.notFound, message: "content with digest \(desc.digest)")
                }
                switch mediaType {
                case MediaTypes.index, MediaTypes.dockerManifestList:
                    let index: Index = try content.decode()
                    out.append(contentsOf: index.manifests)
                case MediaTypes.imageManifest, MediaTypes.dockerManifest:
                    let manifest: Manifest = try content.decode()
                    out.append(manifest.config)
                    out.append(contentsOf: manifest.layers)
                default:
                    continue
                }
            }
            return out
        }
    }
}
