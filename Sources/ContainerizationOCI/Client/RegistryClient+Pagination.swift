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
    /// One page of a list endpoint and the request for the page after it, if any.
    struct ListPage: Sendable {
        let entries: [String]
        let next: URLComponents?
    }

    /// Collect the entries of a list endpoint by following the `Link` header of each page, starting at `first`.
    /// `shouldContinue` is called with each page's entries; returning `false` stops paging.
    static func collectPages(
        from first: URLComponents,
        shouldContinue: ([String]) -> Bool = { _ in true },
        fetch: (URLComponents) async throws -> ListPage
    ) async throws -> [String] {
        var collected: [String] = []
        var components = first
        while true {
            let page = try await fetch(components)
            collected.append(contentsOf: page.entries)

            guard shouldContinue(page.entries), let next = page.next else {
                break
            }
            components = next
        }
        return collected
    }

    /// Request one page of a list endpoint.
    ///
    /// - Parameters:
    ///   - components: The request to send.
    ///   - page: The type a page's JSON body decodes to.
    ///   - entries: Extracts the entries from a decoded page.
    func fetchListPage<Page: Decodable>(
        components: URLComponents,
        page: Page.Type,
        entries: (Page) -> [String]
    ) async throws -> ListPage {
        try await request(components: components) { response in
            guard response.status == .ok else {
                let url = components.url?.absoluteString ?? "unknown"
                let reason = await ErrorResponse.fromResponseBody(response.body)?.jsonString
                throw Error.invalidStatus(url: url, response.status, reason: reason)
            }

            let buffer = try await response.body.collect(upTo: self.bufferSize)
            let decoded = try JSONDecoder().decode(Page.self, from: buffer)
            let next = try Self.nextPage(linkHeader: response.headers["Link"].first, base: self.base)
            return ListPage(entries: entries(decoded), next: next)
        }
    }

    /// The request for the page named by a `Link: <url>; rel="next"` header, or `nil` if there is no header.
    /// Only the path and query of the link are used; the scheme and host come from `base`.
    static func nextPage(linkHeader: String?, base: URLComponents) throws -> URLComponents? {
        guard let linkHeader, !linkHeader.isEmpty else {
            return nil
        }
        let target = linkHeader.prefix { $0 != ";" }.trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
        guard let link = URLComponents(string: target), !link.path.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "invalid next page link: \(linkHeader)")
        }
        var next = base
        next.percentEncodedPath = link.percentEncodedPath
        next.percentEncodedQuery = link.percentEncodedQuery
        return next
    }
}
