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

private struct CatalogResponse: Sendable, Decodable {
    let repositories: [String]
}

extension RegistryClient {
    /// List repositories in the registry.
    ///
    /// Implements GET /v2/_catalog from the OCI Distribution Spec with pagination.
    /// Pages are followed through the response's `Link` header; see `collectPages`.
    /// When prefix is provided, only repositories with that prefix are returned. For a prefix of
    /// two or more characters, pagination skips ahead to the relevant portion of the
    /// lexically-sorted catalog. Pagination stops once results move past the prefix.
    ///
    /// - Parameters:
    ///   - prefix: Optional prefix to filter repository names. An empty prefix is treated as no prefix.
    ///   - maxEntries: The most entries to fetch from the registry, counted before the prefix filter. Throws if the registry returns more.
    /// - Returns: An array of repository names matching the prefix (or all repositories
    ///   if no prefix is given).
    public func catalog(prefix: String? = nil, maxEntries: Int = RegistryClient.defaultMaxListEntries) async throws -> [String] {
        try await Self.collectCatalog(prefix: prefix, maxEntries: maxEntries, base: base) { components in
            try await self.fetchListPage(components: components, page: CatalogResponse.self, entries: \.repositories)
        }
    }

    /// The paging logic of `catalog(prefix:)`, separated from the requests it makes.
    static func collectCatalog(
        prefix: String?,
        maxEntries: Int = defaultMaxListEntries,
        base: URLComponents,
        fetch: (URLComponents) async throws -> ListPage
    ) async throws -> [String] {
        var first = base
        first.path = "/v2/_catalog"

        guard let prefix, !prefix.isEmpty else {
            first.queryItems = listQuery()
            return try await collectPages(from: first, maxEntries: maxEntries, fetch: fetch)
        }

        // The registry returns entries that sort after `last`, so dropping the last
        // character of the prefix starts the listing just before the matching entries.
        // A one-character prefix lists from the start of the catalog.
        if prefix.count >= 2 {
            first.queryItems = listQuery(last: String(prefix.dropLast()))
        } else {
            first.queryItems = listQuery()
        }
        let repos = try await collectPages(
            from: first,
            maxEntries: maxEntries,
            shouldContinue: { page in
                // Stop once the catalog has moved past the prefix.
                guard let lastRepo = page.last else {
                    return true
                }
                return lastRepo.hasPrefix(prefix) || lastRepo <= prefix
            },
            fetch: fetch
        )
        return repos.filter { $0.hasPrefix(prefix) }
    }
}
