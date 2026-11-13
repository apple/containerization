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
    /// The number of entries requested per page with the `n` query parameter.
    static let listPageSize = 100

    /// The default limit on the entries `tags(name:)` and `catalog(prefix:)` collect.
    public static let defaultMaxListEntries = 10_000

    /// The largest number of pages `collectPages` follows.
    static let maxListPages = 1_000

    /// The largest number of consecutive empty pages `collectPages` follows.
    static let maxEmptyListPages = 3

    /// One page of a list endpoint and the request for the page after it, if any.
    struct ListPage: Sendable {
        let entries: [String]
        let next: URLComponents?
    }

    /// Collect the entries of a list endpoint by following the next-page request of each page, starting at `first`.
    /// `shouldContinue` is called with each page's entries; returning `false` stops paging.
    /// Throws if a page requests a page that was already fetched, if more than `maxEntries` entries
    /// or `maxPages` pages are collected, or if `maxEmptyListPages` empty pages follow one another.
    static func collectPages(
        from first: URLComponents,
        maxEntries: Int = defaultMaxListEntries,
        maxPages: Int = maxListPages,
        shouldContinue: ([String]) -> Bool = { _ in true },
        fetch: (URLComponents) async throws -> ListPage
    ) async throws -> [String] {
        var collected: [String] = []
        var requested: Set<URLComponents> = []
        var consecutiveEmptyPages = 0
        var components = first
        while true {
            guard requested.insert(components).inserted else {
                throw ContainerizationError(.invalidState, message: "list pagination returned to an earlier page: \(components.string ?? "")")
            }
            guard requested.count <= maxPages else {
                throw ContainerizationError(.invalidState, message: "list pagination exceeded \(maxPages) pages")
            }

            let page = try await fetch(components)
            collected.append(contentsOf: page.entries)
            guard collected.count <= maxEntries else {
                throw ContainerizationError(.invalidState, message: "list pagination exceeded \(maxEntries) entries")
            }

            if page.entries.isEmpty {
                consecutiveEmptyPages += 1
            } else {
                consecutiveEmptyPages = 0
            }
            guard consecutiveEmptyPages < maxEmptyListPages else {
                throw ContainerizationError(.invalidState, message: "list pagination returned \(maxEmptyListPages) empty pages in a row")
            }

            guard shouldContinue(page.entries), let next = page.next else {
                break
            }
            components = next
        }
        return collected
    }

    /// The query of a list request: a page size and, when given, the entry to start after.
    static func listQuery(last: String? = nil) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "n", value: String(listPageSize))]
        if let last {
            items.append(URLQueryItem(name: "last", value: last))
        }
        return items
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
            let pageEntries = entries(decoded)
            if let next = try Self.nextPage(linkHeaders: response.headers["Link"], base: self.base) {
                try Self.requireSamePath(next: next, request: components)
                return ListPage(entries: pageEntries, next: next)
            }
            return ListPage(entries: pageEntries, next: Self.pageAfter(entries: pageEntries, request: components))
        }
    }

    /// Throws if `next` is not a request for the same path as `request`.
    static func requireSamePath(next: URLComponents, request: URLComponents) throws {
        guard next.path == request.path else {
            throw ContainerizationError(.invalidArgument, message: "next page link \(next.path) is not the listed path \(request.path)")
        }
    }

    /// The request for the page after a full page that had no `Link` header, or `nil` if the page is not full.
    static func pageAfter(entries: [String], request: URLComponents) -> URLComponents? {
        guard entries.count >= listPageSize, let last = entries.last else {
            return nil
        }
        var next = request
        next.queryItems = listQuery(last: last)
        return next
    }

    /// The request for the page named by the `rel="next"` link in `Link` headers, or `nil` if there is none.
    /// Throws if the headers name more than one distinct `rel="next"` target.
    /// Only the path and query of the link are used; the scheme and host come from `base`.
    static func nextPage(linkHeaders: [String], base: URLComponents) throws -> URLComponents? {
        var targets: [String] = []
        for header in linkHeaders {
            for target in linkTargets(header: header, relation: "next") where !targets.contains(target) {
                targets.append(target)
            }
        }
        guard targets.count <= 1 else {
            throw ContainerizationError(.invalidArgument, message: "multiple next page links: \(linkHeaders)")
        }
        guard let target = targets.first else {
            return nil
        }
        guard let link = URLComponents(string: target), !link.path.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "invalid next page link: \(target)")
        }
        var next = base
        next.percentEncodedPath = link.percentEncodedPath
        next.percentEncodedQuery = link.percentEncodedQuery
        return next
    }

    /// The targets of the links in a `Link` header value whose `rel` parameter includes `relation`.
    static func linkTargets(header: String, relation: String) -> [String] {
        var targets: [String] = []
        var remaining = Substring(header)
        while let open = remaining.firstIndex(of: "<"), let close = remaining[open...].firstIndex(of: ">") {
            let target = remaining[remaining.index(after: open)..<close]
            let afterTarget = remaining[remaining.index(after: close)...]
            let parametersEnd = afterTarget.firstIndex(of: "<") ?? afterTarget.endIndex
            if hasRelation(parameters: afterTarget[..<parametersEnd], relation: relation) {
                targets.append(target.trimmingCharacters(in: .whitespaces))
            }
            remaining = afterTarget[parametersEnd...]
        }
        return targets
    }

    /// Whether the `;`-separated link parameters contain a `rel` parameter that names `relation`.
    private static func hasRelation(parameters: Substring, relation: String) -> Bool {
        for parameter in parameters.split(separator: ";") {
            let nameAndValue = parameter.split(separator: "=", maxSplits: 1)
            guard nameAndValue.count == 2 else {
                continue
            }
            let name = nameAndValue[0].trimmingCharacters(in: .whitespaces)
            guard name.lowercased() == "rel" else {
                continue
            }
            let value = nameAndValue[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t,\""))
            if value.lowercased().split(whereSeparator: \.isWhitespace).contains(Substring(relation)) {
                return true
            }
        }
        return false
    }
}
