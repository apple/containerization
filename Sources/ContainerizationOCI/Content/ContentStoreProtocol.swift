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

import Crypto
import Foundation

/// Protocol for defining a content store where OCI image metadata and layers will be managed
/// and manipulated.
public protocol ContentStore: Sendable {
    /// Retrieves a piece of Content based on the digest string.
    /// Returns `nil` if the requested digest is not found.
    func get(digest: String) async throws -> Content?

    /// Retrieves a specific content metadata type based on the digest string.
    /// Returns `nil` if the requested digest is not found.
    func get<T: Decodable>(digest: String) async throws -> T?

    /// Remove a list of digests in the content store.
    @discardableResult
    func delete(digests: [String]) async throws -> ([String], UInt64)

    /// Removes all content from the store except for the digests in the provided list.
    @discardableResult
    func delete(keeping: [String]) async throws -> ([String], UInt64)

    /// Creates a transactional write to the content store.
    /// The function takes a closure given a temporary `URL` of the base directory which all contents should be written to.
    /// This is transaction write where any failed operation in the closure (caught exception) will result in all contents written
    /// in the closure to be deleted.
    ///
    /// If the closure succeeds, then all the content that have been written to the temporary `URL` will be moved into the actual
    /// blobs path of the content store.
    @discardableResult
    func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String]

    /// Creates a new ingest session and returns the session ID and temporary ingest directory corresponding to the session.
    /// The contents from the ingest directory are processed and moved into the content store once the session is marked complete.
    /// This can be done by invoking the `completeIngestSession` method with the returned session ID.
    func newIngestSession() async throws -> (id: String, ingestDir: URL)

    /// Completes a previously started ingest session corresponding to `id`.
    /// The contents from the ingest directory from the session are moved into the content store atomically.
    /// Any failure encountered will result in a transaction failure causing none of the contents to be ingested into the store.
    @discardableResult
    func completeIngestSession(_ id: String) async throws -> [String]

    /// Cancels a previously started ingest session corresponding to `id`.
    /// The contents from the ingest directory corresponding to the session are removed.
    func cancelIngestSession(_ id: String) async throws
}
