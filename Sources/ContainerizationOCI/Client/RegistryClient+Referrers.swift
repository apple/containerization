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

import AsyncHTTPClient
import ContainerizationError
import Foundation
import NIOFoundationCompat

extension RegistryClient {
    /// Query the OCI referrers API for artifacts that reference a given manifest digest.
    ///
    /// Implements `GET /v2/{name}/referrers/{digest}` from the OCI Distribution Spec v1.1.
    /// Falls back to the referrers tag schema when the API is not available (404).
    ///
    /// - Parameters:
    ///   - name: The repository name (e.g., "library/ubuntu").
    ///   - digest: The digest of the subject manifest (e.g., "sha256:abc123...").
    ///   - artifactType: Optional filter to return only referrers with a matching artifactType.
    /// - Returns: An `Index` whose `manifests` array contains descriptors of referring artifacts.
    ///            Returns an empty index if the registry does not support the referrers API
    ///            and no tag schema fallback is available.
    public func referrers(name: String, digest: String, artifactType: String? = nil) async throws -> Index {
        var components = base
        components.path = "/v2/\(name)/referrers/\(digest)"

        if let artifactType {
            components.queryItems = [URLQueryItem(name: "artifactType", value: artifactType)]
        }

        let headers = [("Accept", MediaTypes.index)]

        let result: Index = try await request(components: components, method: .GET, headers: headers) { response in
            if response.status == .notFound {
                return await self.referrersTagFallback(name: name, digest: digest, artifactType: artifactType)
            }

            guard response.status == .ok else {
                let url = components.url?.absoluteString ?? "unknown"
                let reason = await ErrorResponse.fromResponseBody(response.body)?.jsonString
                throw Error.invalidStatus(url: url, response.status, reason: reason)
            }

            let buffer = try await response.body.collect(upTo: self.bufferSize)
            return try JSONDecoder().decode(Index.self, from: buffer)
        }

        return result
    }

    /// Fallback for registries that don't support the referrers API.
    ///
    /// Uses the OCI referrers tag schema: referrers for a digest are stored as an
    /// index at the tag `<algorithm>-<hex>` (e.g., `sha256-abc123...`).
    private func referrersTagFallback(name: String, digest: String, artifactType: String? = nil) async -> Index {
        let referrerTag = digest.replacingOccurrences(of: ":", with: "-")

        let descriptor: Descriptor
        do {
            descriptor = try await resolve(name: name, tag: referrerTag)
        } catch {
            return Index(schemaVersion: 2, manifests: [])
        }

        let index: Index
        do {
            index = try await fetch(name: name, descriptor: descriptor)
        } catch {
            return Index(schemaVersion: 2, manifests: [])
        }

        guard let artifactType else {
            return index
        }

        let filtered = index.manifests.filter { $0.artifactType == artifactType }
        return Index(schemaVersion: 2, manifests: filtered)
    }
}
