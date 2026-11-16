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
import NIOHTTP1
import NIOPosix
import Testing

@testable import ContainerizationOCI

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var uris: [String] = []

    func append(_ uri: String) {
        lock.withLock { uris.append(uri) }
    }

    var all: [String] {
        lock.withLock { uris }
    }
}

/// `tags(name:)` and `catalog(prefix:)` against a local registry that serves list pages.
struct RegistryClientListEndpointTests {
    private static let group = MultiThreadedEventLoopGroup.singleton

    private static func client(port: Int) -> RegistryClient {
        RegistryClient(host: "127.0.0.1", scheme: "http", port: port)
    }

    private static func tagsBody(_ tags: [String]) -> Data {
        Data(#"{"name":"org/app","tags":[\#(tags.map { "\"\($0)\"" }.joined(separator: ","))]}"#.utf8)
    }

    private static func catalogBody(_ repositories: [String]) -> Data {
        Data(#"{"repositories":[\#(repositories.map { "\"\($0)\"" }.joined(separator: ","))]}"#.utf8)
    }

    private static func ok(_ body: Data, link: String? = nil) -> MockRegistryResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        if let link {
            headers.add(name: "Link", value: link)
        }
        return .status(.ok, headers: headers, body: body)
    }

    private static func numbered(_ prefix: String, _ range: Range<Int>) -> [String] {
        range.map { "\(prefix)\($0)" }
    }

    @Test func tagsFollowsLinkHeader() async throws {
        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            switch request.uri {
            case "/v2/org/app/tags/list?n=100":
                Self.ok(Self.tagsBody(["1.0", "1.1"]), link: #"</v2/org/app/tags/list?last=1.1&n=100>; rel="next""#)
            case "/v2/org/app/tags/list?last=1.1&n=100":
                Self.ok(Self.tagsBody(["2.0"]))
            default:
                .status(.notFound)
            }
        }
        defer { Task { try? await server.shutdown() } }

        let tags = try await Self.client(port: server.port).tags(name: "org/app")

        #expect(tags == ["1.0", "1.1", "2.0"])
    }

    /// A `Link` header without `rel="next"` does not name a next page.
    @Test func tagsIgnoresLinkWithoutNextRelation() async throws {
        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            guard request.uri == "/v2/org/app/tags/list?n=100" else {
                return .status(.notFound)
            }
            return Self.ok(Self.tagsBody(["1.0"]), link: #"</v2/org/app/tags/list?last=0.9>; rel="prev""#)
        }
        defer { Task { try? await server.shutdown() } }

        let tags = try await Self.client(port: server.port).tags(name: "org/app")

        #expect(tags == ["1.0"])
    }

    @Test func tagsThrowsWhenLinkNamesAnotherPath() async throws {
        let requests = RequestLog()
        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            requests.append(request.uri)
            return Self.ok(Self.tagsBody(["1.0"]), link: #"</v2/other/manifests/latest>; rel="next""#)
        }
        defer { Task { try? await server.shutdown() } }

        await #expect(throws: (any Error).self) {
            try await Self.client(port: server.port).tags(name: "org/app")
        }
        #expect(requests.all == ["/v2/org/app/tags/list?n=100"])
    }

    @Test func tagsUsesFullPageFallbackWithoutLinkHeader() async throws {
        let firstPage = Self.numbered("t", 100..<200)
        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            switch request.uri {
            case "/v2/org/app/tags/list?n=100":
                Self.ok(Self.tagsBody(firstPage))
            case "/v2/org/app/tags/list?n=100&last=t199":
                Self.ok(Self.tagsBody(["t200"]))
            default:
                .status(.notFound)
            }
        }
        defer { Task { try? await server.shutdown() } }

        let tags = try await Self.client(port: server.port).tags(name: "org/app")

        #expect(tags == firstPage + ["t200"])
    }

    @Test func tagsPrefersLinkHeaderOverFallback() async throws {
        let firstPage = Self.numbered("t", 100..<200)
        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            switch request.uri {
            case "/v2/org/app/tags/list?n=100":
                Self.ok(Self.tagsBody(firstPage), link: #"</v2/org/app/tags/list?last=cursor&n=100>; rel="next""#)
            case "/v2/org/app/tags/list?last=cursor&n=100":
                Self.ok(Self.tagsBody(["t200"]))
            default:
                .status(.notFound)
            }
        }
        defer { Task { try? await server.shutdown() } }

        let tags = try await Self.client(port: server.port).tags(name: "org/app")

        #expect(tags == firstPage + ["t200"])
    }

    @Test func tagsThrowsWhenRegistryIgnoresLast() async throws {
        let page = Self.numbered("t", 100..<200)
        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { _ in
            Self.ok(Self.tagsBody(page))
        }
        defer { Task { try? await server.shutdown() } }

        await #expect(throws: (any Error).self) {
            try await Self.client(port: server.port).tags(name: "org/app")
        }
    }

    @Test func tagsThrowsPastMaxEntries() async throws {
        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { _ in
            Self.ok(Self.tagsBody(["1.0", "1.1", "1.2"]))
        }
        defer { Task { try? await server.shutdown() } }

        await #expect(throws: (any Error).self) {
            try await Self.client(port: server.port).tags(name: "org/app", maxEntries: 2)
        }
    }

    @Test func catalogUsesFullPageFallbackWithoutLinkHeader() async throws {
        let firstPage = Self.numbered("org/r", 100..<200)
        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            switch request.uri {
            case "/v2/_catalog?n=100":
                Self.ok(Self.catalogBody(firstPage))
            case "/v2/_catalog?n=100&last=org/r199":
                Self.ok(Self.catalogBody(["org/r200"]))
            default:
                .status(.notFound)
            }
        }
        defer { Task { try? await server.shutdown() } }

        let repositories = try await Self.client(port: server.port).catalog()

        #expect(repositories == firstPage + ["org/r200"])
    }

    @Test func catalogWithSingleCharacterPrefixFilters() async throws {
        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            guard request.uri == "/v2/_catalog?n=100" else {
                return .status(.notFound)
            }
            return Self.ok(Self.catalogBody(["org/a", "team/b", "tools/lint", "zoo/c"]))
        }
        defer { Task { try? await server.shutdown() } }

        let repositories = try await Self.client(port: server.port).catalog(prefix: "t")

        #expect(repositories == ["team/b", "tools/lint"])
    }
}
