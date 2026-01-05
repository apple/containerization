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

// swiftlint:disable unused_optional_binding

import ContainerizationError
import ContainerizationExtras
import Crypto
import Foundation

/// A `ContentStore` implementation that stores content on the local filesystem.
public actor LocalContentStore: ContentStore {
    private static let encoder = JSONEncoder()

    private let _basePath: URL
    private let _ingestPath: URL
    private let _blobPath: URL
    private let _lock: AsyncLock

    private var activeIngestSessions: AsyncSet<String> = AsyncSet([])

    /// Create a new `LocalContentStore`.
    ///
    /// - Parameters:
    ///   - path: The path where content should be written under.
    public init(path: URL) throws {
        let ingestPath = path.appendingPathComponent("ingest")
        let blobPath = path.appendingPathComponent("blobs/sha256")

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: ingestPath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobPath, withIntermediateDirectories: true)

        self._basePath = path
        self._ingestPath = ingestPath
        self._blobPath = blobPath
        self._lock = AsyncLock()
        Self.encoder.outputFormatting = .sortedKeys
    }

    /// Get a piece of content from the store. Returns nil if not
    /// found.
    ///
    /// - Parameters:
    ///   - digest: The string digest of the content.
    public func get(digest: String) throws -> Content? {
        let d = digest.trimmingDigestPrefix
        let path = self._blobPath.appendingPathComponent(d)
        do {
            return try LocalContent(path: path)
        } catch let err as ContainerizationError {
            switch err.code {
            case .notFound:
                return nil
            default:
                throw err
            }
        }
    }

    /// Get a piece of content from the store and return the decoded version of
    /// it.
    ///
    /// - Parameters:
    ///   - digest: The string digest of the content.
    public func get<T: Decodable & Sendable>(digest: String) throws -> T? {
        guard let content: Content = try self.get(digest: digest) else {
            return nil
        }
        return try content.decode()
    }

    /// Delete all content besides a set provided.
    ///
    /// - Parameters:
    ///   - keeping: The set of string digests to keep.
    public func delete(keeping: [String]) async throws -> ([String], UInt64) {
        let fileManager = FileManager.default
        let all = try fileManager.contentsOfDirectory(at: self._blobPath, includingPropertiesForKeys: nil)
        let allDigests = Set(all.map { $0.lastPathComponent })
        let toDelete = allDigests.subtracting(keeping)
        return try await self.delete(digests: Array(toDelete))
    }

    /// Delete a specific set of content.
    ///
    /// - Parameters:
    ///   - digests: Array of strings denoting the digests of the content to delete.
    @discardableResult
    public func delete(digests: [String]) async throws -> ([String], UInt64) {
        let store = AsyncStore<([String], UInt64)>()
        try await self._lock.withLock { context in
            let fileManager = FileManager.default
            var deleted: [String] = []
            var deletedBytes: UInt64 = 0
            for toDelete in digests {
                let p = self._blobPath.appendingPathComponent(toDelete)
                guard let content = try? LocalContent(path: p) else {
                    continue
                }
                deletedBytes += try content.size()
                try fileManager.removeItem(at: p)
                deleted.append(toDelete)
            }
            await store.set((deleted, deletedBytes))
        }
        return await store.get() ?? ([], 0)
    }

    /// Creates a transactional write to the content store.
    ///
    /// - Parameters:
    ///   - body: Closure that is given a temporary `URL` of the base directory which all contents should be written to.
    /// This is a transaction write where any failed operation in the closure (caught exception) will result in all contents written
    /// in the closure to be deleted. If the closure succeeds, then all the content that have been written to the temporary `URL`
    /// will be moved into the actual blobs path of the content store.
    @discardableResult
    public func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String] {
        let (id, tempPath) = try await self.newIngestSession()
        try await body(tempPath)
        return try await self.completeIngestSession(id)
    }

    /// Creates a new ingest session and returns the session ID and temporary ingest directory corresponding to the session.
    /// The contents from the ingest directory are processed and moved into the content store once the session is marked complete.
    /// This can be done by invoking the `completeIngestSession` method with the returned session ID.
    public func newIngestSession() async throws -> (id: String, ingestDir: URL) {
        let id = UUID().uuidString
        let temporaryPath = self._ingestPath.appendingPathComponent(id)
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: temporaryPath.path, withIntermediateDirectories: true)
        await self.activeIngestSessions.insert(id)
        return (id, temporaryPath)
    }

    /// Completes a previously started ingest session corresponding to `id`. The contents from the ingest
    /// directory from the session are moved into the content store atomically. Any failure encountered will
    /// result in a transaction failure causing none of the contents to be ingested into the store.
    /// - Parameters:
    ///   - id: id of the ingest session to complete.
    @discardableResult
    public func completeIngestSession(_ id: String) async throws -> [String] {
        guard await activeIngestSessions.contains(id) else {
            throw ContainerizationError(.internalError, message: "invalid session id \(id)")
        }
        await activeIngestSessions.remove(id)
        let temporaryPath = self._ingestPath.appendingPathComponent(id)
        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(at: temporaryPath)
        }
        let tempDigests: [URL] = try fileManager.contentsOfDirectory(at: temporaryPath, includingPropertiesForKeys: nil)
        return try await self._lock.withLock { context in
            var moved: [String] = []
            let fileManager = FileManager.default
            do {
                try tempDigests.forEach {
                    let digest = $0.lastPathComponent
                    let target = self._blobPath.appendingPathComponent(digest)
                    // only ingest if not exists
                    if !fileManager.fileExists(atPath: target.path) {
                        try fileManager.moveItem(at: $0, to: target)
                        moved.append(digest)
                    }
                }
            } catch {
                moved.forEach {
                    try? fileManager.removeItem(at: self._blobPath.appendingPathComponent($0))
                }
                throw error
            }
            return tempDigests.map { $0.lastPathComponent }
        }
    }

    /// Cancels a previously started ingest session corresponding to `id`.
    /// The contents from the ingest directory corresponding to the session are removed.
    /// - Parameters:
    ///   - id: id of the ingest session to complete.
    public func cancelIngestSession(_ id: String) async throws {
        guard let _ = await self.activeIngestSessions.remove(id) else {
            return
        }
        let temporaryPath = self._ingestPath.appendingPathComponent(id)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: temporaryPath)
    }
}
