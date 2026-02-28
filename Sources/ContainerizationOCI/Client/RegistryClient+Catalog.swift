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

private struct CatalogResponse: Sendable, Decodable {
    let repositories: [String]
}

extension RegistryClient {
    /// List repositories in the registry.
    ///
    /// Implements GET /v2/_catalog from the OCI Distribution Spec with pagination.
    /// When prefix is provided, pagination skips ahead to the relevant portion of
    /// the lexically-sorted catalog and stops once results move past the prefix.
    ///
    /// - Parameter prefix: Optional prefix to filter repository names. Must be at least
    ///   two characters long to enable the skip-ahead optimization; shorter values are
    ///   treated as no prefix.
    /// - Returns: An array of repository names matching the prefix (or all repositories
    ///   if no prefix is given).
    public func catalog(prefix: String? = nil) async throws -> [String] {
        let effectivePrefix = prefix.flatMap { $0.count >= 2 ? $0 : nil }

        var allRepos: [String] = []
        // When a prefix is provided, skip ahead in the lexically-sorted catalog
        // by setting last to one position before the prefix. The OCI spec
        // returns entries that sort after last, so dropping the last character
        // of the prefix positions the cursor just before matching entries.
        var last: String? = effectivePrefix.map { String($0.dropLast()) }
        let pageSize = 100

        while true {
            var components = base
            components.path = "/v2/_catalog"
            var queryItems = [URLQueryItem(name: "n", value: String(pageSize))]
            if let last {
                queryItems.append(URLQueryItem(name: "last", value: last))
            }
            components.queryItems = queryItems

            let repos: [String] = try await request(components: components) { response in
                guard response.status == .ok else {
                    let url = components.url?.absoluteString ?? "unknown"
                    let reason = await ErrorResponse.fromResponseBody(response.body)?.jsonString
                    throw Error.invalidStatus(url: url, response.status, reason: reason)
                }

                let buffer = try await response.body.collect(upTo: self.bufferSize)
                return try JSONDecoder().decode(CatalogResponse.self, from: buffer).repositories
            }

            if let effectivePrefix {
                let matching = repos.filter { $0.hasPrefix(effectivePrefix) }
                allRepos.append(contentsOf: matching)
                if let lastRepo = repos.last, !lastRepo.hasPrefix(effectivePrefix) && lastRepo > effectivePrefix {
                    break
                }
            } else {
                allRepos.append(contentsOf: repos)
            }

            if repos.count < pageSize { break }
            last = repos.last
        }

        return allRepos
    }
}
