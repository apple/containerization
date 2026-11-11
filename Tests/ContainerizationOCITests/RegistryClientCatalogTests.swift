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

/// The paging logic of `catalog(prefix:)`, driven by an in-memory endpoint.
struct RegistryClientCatalogTests {
    @Test func listsEverythingWithoutPrefix() async throws {
        let endpoint = FakeListEndpoint { _ in page(["org/a", "team/b"]) }

        let repositories = try await RegistryClient.collectCatalog(prefix: nil, base: testBase, fetch: endpoint.fetch)

        #expect(repositories == ["org/a", "team/b"])
        #expect(endpoint.requests == ["/v2/_catalog"])
    }

    @Test func treatsShortPrefixAsNone() async throws {
        let endpoint = FakeListEndpoint { _ in page(["org/a", "team/b"]) }

        let repositories = try await RegistryClient.collectCatalog(prefix: "t", base: testBase, fetch: endpoint.fetch)

        #expect(repositories == ["org/a", "team/b"])
        #expect(endpoint.requests == ["/v2/_catalog"])
    }

    @Test func prefixSkipsAheadFiltersAndStopsPastPrefix() async throws {
        let endpoint = FakeListEndpoint { _ in
            page(["team/app", "team/web", "tools/lint"], next: "/v2/_catalog?last=tools%2Flint")
        }

        let repositories = try await RegistryClient.collectCatalog(prefix: "team/", base: testBase, fetch: endpoint.fetch)

        #expect(repositories == ["team/app", "team/web"])
        #expect(endpoint.requests == ["/v2/_catalog?last=team"])
    }

    @Test func prefixContinuesWhilePageStillMatches() async throws {
        let endpoint = FakeListEndpoint { request in
            request == "/v2/_catalog?last=team"
                ? page(["team/a", "team/b"], next: "/v2/_catalog?last=team%2Fb")
                : page(["team/c", "tools/lint"], next: "/v2/_catalog?last=tools%2Flint")
        }

        let repositories = try await RegistryClient.collectCatalog(prefix: "team/", base: testBase, fetch: endpoint.fetch)

        #expect(repositories == ["team/a", "team/b", "team/c"])
        #expect(endpoint.requests == ["/v2/_catalog?last=team", "/v2/_catalog?last=team%2Fb"])
    }

    @Test func prefixWithNoMatchesReturnsNothing() async throws {
        let endpoint = FakeListEndpoint { _ in page(["tools/lint"], next: "/v2/_catalog?last=tools%2Flint") }

        let repositories = try await RegistryClient.collectCatalog(prefix: "team/", base: testBase, fetch: endpoint.fetch)

        #expect(repositories.isEmpty)
        #expect(endpoint.requests == ["/v2/_catalog?last=team"])
    }
}
