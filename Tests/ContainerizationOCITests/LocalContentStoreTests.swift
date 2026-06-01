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

import Foundation
import Testing

@testable import ContainerizationOCI

@Suite
struct LocalContentStoreTests {
    private static let digestA = String(repeating: "a", count: 64)
    private static let digestB = String(repeating: "b", count: 64)

    @Test func totalAllocatedSizeReportsZeroForEmptyStore() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let size = try await store.totalAllocatedSize()
        #expect(size == 0)
    }

    @Test func totalAllocatedSizeReflectsCommittedBlobs() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let payload = Data(repeating: 0xAB, count: 64 * 1024)

        try await store.ingest { tempDir in
            try payload.write(to: tempDir.appendingPathComponent(Self.digestA))
        }

        let size = try await store.totalAllocatedSize()
        #expect(size >= UInt64(payload.count))
    }

    @Test func totalAllocatedSizeIncludesInFlightIngest() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let payload = Data(repeating: 0xCD, count: 32 * 1024)

        let session = try await store.newIngestSession()
        try payload.write(to: session.ingestDir.appendingPathComponent(Self.digestB))

        let size = try await store.totalAllocatedSize()
        #expect(size >= UInt64(payload.count))

        try await store.cancelIngestSession(session.id)
    }
}
