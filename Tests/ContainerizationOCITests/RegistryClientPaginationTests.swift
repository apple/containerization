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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerizationOCI

let testBase: URLComponents = {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "registry.test"
    return components
}()

func testRequest(_ pathAndQuery: String) -> URLComponents {
    URLComponents(string: "https://registry.test" + pathAndQuery) ?? testBase
}

/// An in-memory list endpoint: answers each request with the page the supplied
/// closure picks and records the requests it received as `path?query` strings.
final class FakeListEndpoint {
    private let respond: (_ request: String) throws -> RegistryClient.ListPage
    private(set) var requests: [String] = []

    init(_ respond: @escaping (_ request: String) throws -> RegistryClient.ListPage) {
        self.respond = respond
    }

    func fetch(_ components: URLComponents) throws -> RegistryClient.ListPage {
        var request = components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            request += "?" + query
        }
        requests.append(request)
        return try respond(request)
    }
}

func page(_ entries: [String], next: String? = nil) -> RegistryClient.ListPage {
    RegistryClient.ListPage(entries: entries, next: next.map(testRequest))
}

struct RegistryClientPaginationTests {
    @Test func returnsSinglePage() async throws {
        let endpoint = FakeListEndpoint { _ in page(["a", "b"]) }

        let entries = try await RegistryClient.collectPages(from: testRequest("/list"), fetch: endpoint.fetch)

        #expect(entries == ["a", "b"])
        #expect(endpoint.requests == ["/list"])
    }

    @Test func followsNextRequestsUntilThereIsNone() async throws {
        let endpoint = FakeListEndpoint { request in
            switch request {
            case "/list": page(["a", "b"], next: "/list?last=b")
            case "/list?last=b": page(["c", "d"], next: "/list?last=d")
            default: page(["e"])
            }
        }

        let entries = try await RegistryClient.collectPages(from: testRequest("/list"), fetch: endpoint.fetch)

        #expect(entries == ["a", "b", "c", "d", "e"])
        #expect(endpoint.requests == ["/list", "/list?last=b", "/list?last=d"])
    }

    @Test func stopsWhenAskedToEvenIfMorePagesFollow() async throws {
        let endpoint = FakeListEndpoint { _ in page(["a", "b"], next: "/list?last=b") }

        let entries = try await RegistryClient.collectPages(from: testRequest("/list"), shouldContinue: { _ in false }, fetch: endpoint.fetch)

        #expect(entries == ["a", "b"])
        #expect(endpoint.requests == ["/list"])
    }

    @Test func propagatesFetchErrors() async throws {
        let endpoint = FakeListEndpoint { request in
            guard request == "/list" else {
                throw ContainerizationError(.internalError, message: "page failed")
            }
            return page(["a"], next: "/list?last=a")
        }

        await #expect(throws: ContainerizationError.self) {
            try await RegistryClient.collectPages(from: testRequest("/list"), fetch: endpoint.fetch)
        }
        #expect(endpoint.requests == ["/list", "/list?last=a"])
    }

    struct LinkTestCase: Sendable, CustomTestStringConvertible {
        let linkHeader: String
        let expected: String

        var testDescription: String {
            linkHeader
        }
    }

    /// Only the path and query of the link are used; the host always comes from the client's base URL.
    @Test(arguments: [
        LinkTestCase(linkHeader: #"</v2/org/app/tags/list?last=b&n=2>; rel="next""#, expected: "https://registry.test/v2/org/app/tags/list?last=b&n=2"),
        LinkTestCase(linkHeader: "</v2/_catalog?last=org%2Fapp&n=100>; rel=next", expected: "https://registry.test/v2/_catalog?last=org%2Fapp&n=100"),
        LinkTestCase(linkHeader: #"<https://elsewhere.invalid/v2/org/app/tags/list?last=b>; rel="next""#, expected: "https://registry.test/v2/org/app/tags/list?last=b"),
        LinkTestCase(linkHeader: #"</v2/org/app/tags/list>; rel="next""#, expected: "https://registry.test/v2/org/app/tags/list"),
    ])
    func nextPage(testCase: LinkTestCase) throws {
        let next = try RegistryClient.nextPage(linkHeader: testCase.linkHeader, base: testBase)

        #expect(next?.string == testCase.expected)
    }

    @Test(arguments: [nil, ""])
    func nextPageIsNilWithoutLinkHeader(linkHeader: String?) throws {
        #expect(try RegistryClient.nextPage(linkHeader: linkHeader, base: testBase) == nil)
    }

    @Test func nextPageThrowsWithoutPath() {
        #expect(throws: ContainerizationError.self) {
            try RegistryClient.nextPage(linkHeader: #"<>; rel="next""#, base: testBase)
        }
    }
}
