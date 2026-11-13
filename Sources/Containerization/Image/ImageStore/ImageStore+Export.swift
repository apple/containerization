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
import NIO
import Synchronization

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
        public func export(index: Descriptor, platforms: (Platform) -> Bool, filter: (Descriptor) -> Bool = { _ in true }) async throws -> Descriptor {
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
                        for desc in chunk.filter(filter) {
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
            // The descriptor's mediaType becomes the HTTP Content-Type in
            // RegistryClient.push and must match the mediaType field inside
            // localIndexData. Registries reject mismatches with MANIFEST_INVALID.
            let descriptor = Descriptor(
                mediaType: index.mediaType,
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
                        .addTotalSize(desc.size),
                        .addTotalItems(1),
                    ])
                }
            }
            await progress?([
                .addTotalSize(Int64(localIndexData.count)),
                .addTotalItems(1),
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
            // Report the bytes as the client consumes the stream rather than once the whole blob
            // has been pushed, so that progress moves during the upload of a large layer.
            let pushed = PushedSize()
            let progress = self.progress
            do {
                let generator = {
                    try stream.reset()
                    // The client calls the generator again when it retries the request. The new
                    // attempt starts from zero and its bytes replace those of the previous one.
                    pushed.restart()
                    return ProgressReportingStream(base: stream.stream) { bytes in
                        let delta = pushed.advance(by: bytes)
                        if delta != 0 {
                            await progress?([.addSize(delta)])
                        }
                    }
                }
                try await client.push(name: name, ref: tag, descriptor: descriptor, streamGenerator: generator, progress: progress)
                await progress?([
                    .addSize(pushed.settle(at: descriptor.size)),
                    .addItems(1),
                ])
            } catch let err as ContainerizationError where err.code == .exists {
                // We reported the total items and size and have to account for them in existing content.
                await progress?([
                    .addSize(pushed.settle(at: descriptor.size)),
                    .addItems(1),
                ])
            } catch {
                // Take back what a failed upload had reported.
                let delta = pushed.settle(at: 0)
                if delta != 0 {
                    await progress?([.addSize(delta)])
                }
                throw error
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

/// An `AsyncSequence` of `ByteBuffer` that calls `onConsumed` with the size of each buffer once its
/// consumer has finished with it, that is, when the consumer asks for the next buffer or reaches the
/// end of the sequence.
struct ProgressReportingStream<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == ByteBuffer {
    typealias Element = ByteBuffer

    let base: Base
    let onConsumed: @Sendable (Int64) async -> Void

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        let onConsumed: @Sendable (Int64) async -> Void
        var pending: Int64 = 0

        mutating func next() async throws -> ByteBuffer? {
            if pending > 0 {
                await onConsumed(pending)
                pending = 0
            }
            guard let buffer = try await base.next() else {
                return nil
            }
            pending = Int64(buffer.readableBytes)
            return buffer
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), onConsumed: onConsumed)
    }
}

/// The bytes of one blob reported through a progress handler, kept consistent when the upload is
/// retried: every method returns the change to report so that the reported total follows the
/// current attempt.
final class PushedSize: Sendable {
    private struct State {
        var attempt: Int64 = 0
        var reported: Int64 = 0
    }

    private let state = Mutex(State())

    /// Start a new upload attempt.
    func restart() {
        state.withLock { $0.attempt = 0 }
    }

    /// Count `bytes` more for the current attempt.
    func advance(by bytes: Int64) -> Int64 {
        state.withLock { state in
            state.attempt += bytes
            let delta = state.attempt - state.reported
            state.reported = state.attempt
            return delta
        }
    }

    /// Move the reported total to `total`.
    func settle(at total: Int64) -> Int64 {
        state.withLock { state in
            let delta = total - state.reported
            state.reported = total
            return delta
        }
    }
}
