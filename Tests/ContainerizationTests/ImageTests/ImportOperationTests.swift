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

import ContainerizationArchive
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing

@testable import Containerization

@Suite
struct ImportOperationTests {
    /// A content store that loses each blob right after it reports the blob, the way a garbage
    /// collection that runs beside an import would.
    private struct VanishingContentStore: ContentStore {
        let store: LocalContentStore

        func get(digest: String) async throws -> Content? {
            guard let content = try await self.store.get(digest: digest) else {
                return nil
            }
            try await self.store.delete(digests: [digest])
            return content
        }

        func get<T: Decodable>(digest: String) async throws -> T? {
            let content: Content? = try await self.get(digest: digest)
            return try content?.decode()
        }

        func delete(digests: [String]) async throws -> ([String], UInt64) {
            try await self.store.delete(digests: digests)
        }

        func delete(keeping: [String]) async throws -> ([String], UInt64) {
            try await self.store.delete(keeping: keeping)
        }

        func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String] {
            try await self.store.ingest(body)
        }

        func newIngestSession() async throws -> (id: String, ingestDir: URL) {
            try await self.store.newIngestSession()
        }

        func completeIngestSession(_ id: String) async throws -> [String] {
            try await self.store.completeIngestSession(id)
        }

        func cancelIngestSession(_ id: String) async throws {
            try await self.store.cancelIngestSession(id)
        }

        func totalAllocatedSize() async throws -> UInt64 {
            try await self.store.totalAllocatedSize()
        }
    }

    @Test func importFetchesBlobsThatLeaveTheContentStore() async throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = root.appendingPathComponent("layout")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        let tar = try #require(Foundation.Bundle.module.url(forResource: "scratch", withExtension: "tar"))
        let rejected = try ArchiveReader(format: .pax, filter: .none, file: tar).extractContents(to: layout)
        #expect(rejected.isEmpty)

        let content = try LocalContentStore(path: root.appendingPathComponent("content"))
        _ = try await ImageStore(path: root.appendingPathComponent("store"), contentStore: content).load(from: layout)

        let client = try LocalOCILayoutClient(root: layout)
        let descriptor = try #require(try client.loadIndexFromOCILayout(directory: layout).manifests.first)
        let name = try Reference.parse(client.getImageReferencefromDescriptor(descriptor: descriptor)).path
        let (_, ingestDir) = try await content.newIngestSession()

        _ = try await ImageStore.ImportOperation(
            name: name, contentStore: VanishingContentStore(store: content), client: client, ingestDir: ingestDir
        ).import(root: descriptor, matcher: createPlatformMatcher(for: nil))

        // The layer was deleted from the store during the import, and the import fetched it again.
        let layer = "530a471644602a73c05568aa468506f7a630f6c0a0e43e9052f1f4469d8241cf"
        #expect(try await content.get(digest: "sha256:\(layer)") == nil)
        let fetched = try LocalContent(path: ingestDir.appendingPathComponent(layer))
        #expect(try fetched.digest().digestString == "sha256:\(layer)")
    }
}
