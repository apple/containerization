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

extension RegistryClient {
    /// A page of GET /v2/<name>/tags/list.
    struct TagsResponse: Sendable, Decodable {
        // The distribution spec allows `tags` to be null for a repository without tags.
        let tags: [String]?

        var entries: [String] {
            tags ?? []
        }
    }

    /// List the tags of a repository.
    ///
    /// Implements GET /v2/<name>/tags/list from the OCI Distribution Spec with pagination.
    /// Pages are followed through the response's `Link` header.
    ///
    /// - Parameter name: The repository name (e.g., "library/alpine").
    /// - Returns: The repository's tags in the order the registry returned them.
    public func tags(name: String) async throws -> [String] {
        var first = base
        first.path = "/v2/\(name)/tags/list"

        return try await Self.collectPages(from: first) { components in
            try await self.fetchListPage(components: components, page: TagsResponse.self, entries: \.entries)
        }
    }
}
