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

import Crypto
import Foundation
import NIOHTTP1
import NIOPosix
import Testing

@testable import ContainerizationOCI

/// Pulling by digest must not accept content the registry substitutes
/// for the pinned digest.
///
/// Each test runs a small local registry that can present invalid data
/// to the client.
@Suite("RegistryClient digest verification")
struct RegistryClientDigestVerificationTests {
    private static let group = MultiThreadedEventLoopGroup.singleton
    private static let repoName = "victim/legit-image"

    private static func client(port: Int) -> RegistryClient {
        RegistryClient(host: "127.0.0.1", scheme: "http", port: port)
    }

    // MARK: - resolve()

    @Test("resolve rejects a registry that answers a digest pin with a different digest")
    func resolveRejectsDigestMismatch() async throws {
        let attackerDigest = "sha256:" + String(repeating: "b", count: 64)
        let pin = "sha256:" + String(repeating: "a", count: 64)

        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            #expect(request.method == .HEAD)
            var headers = HTTPHeaders()
            headers.add(name: "Docker-Content-Digest", value: attackerDigest)
            headers.add(name: "Content-Type", value: MediaTypes.imageManifest)
            headers.add(name: "Content-Length", value: "0")
            return .status(.ok, headers: headers)
        }
        defer { Task { try? await server.shutdown() } }

        let client = Self.client(port: server.port)
        await #expect(throws: (any Error).self) {
            try await client.resolve(name: Self.repoName, tag: pin)
        }
    }

    @Test("resolve accepts a registry that honestly answers a digest pin")
    func resolveAcceptsMatchingDigest() async throws {
        let pin = "sha256:" + String(repeating: "a", count: 64)

        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            var headers = HTTPHeaders()
            headers.add(name: "Docker-Content-Digest", value: pin)
            headers.add(name: "Content-Type", value: MediaTypes.imageManifest)
            headers.add(name: "Content-Length", value: "0")
            return .status(.ok, headers: headers)
        }
        defer { Task { try? await server.shutdown() } }

        let client = Self.client(port: server.port)
        let descriptor = try await client.resolve(name: Self.repoName, tag: pin)
        #expect(descriptor.digest == pin)
    }

    @Test("resolve does not enforce digest equality when resolving a mutable tag")
    func resolveDoesNotEnforceDigestForTags() async throws {
        let registryDigest = "sha256:" + String(repeating: "c", count: 64)

        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            var headers = HTTPHeaders()
            headers.add(name: "Docker-Content-Digest", value: registryDigest)
            headers.add(name: "Content-Type", value: MediaTypes.imageManifest)
            headers.add(name: "Content-Length", value: "0")
            return .status(.ok, headers: headers)
        }
        defer { Task { try? await server.shutdown() } }

        let client = Self.client(port: server.port)
        // "latest" is a tag, not a pin -- whatever the registry currently claims for it
        // is exactly what a tag means. No caller-side expectation exists to violate.
        let descriptor = try await client.resolve(name: Self.repoName, tag: "latest")
        #expect(descriptor.digest == registryDigest)
    }

    // MARK: - fetch / fetchData content verification

    private struct DummyPayload: Codable, Equatable {
        let hello: String
    }

    @Test("fetchData rejects a body that doesn't hash to the descriptor's digest")
    func fetchDataRejectsContentDigestMismatch() async throws {
        let body = Data(#"{"hello":"attacker"}"#.utf8)
        let claimedDigest = "sha256:" + String(repeating: "d", count: 64)  // does not match `body`
        let descriptor = Descriptor(mediaType: MediaTypes.imageManifest, digest: claimedDigest, size: Int64(body.count))

        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            #expect(request.method == .GET)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: MediaTypes.imageManifest)
            return .status(.ok, headers: headers, body: body)
        }
        defer { Task { try? await server.shutdown() } }

        let client = Self.client(port: server.port)
        await #expect(throws: (any Error).self) {
            try await client.fetchData(name: Self.repoName, descriptor: descriptor)
        }
    }

    @Test("fetchData accepts a body that matches the descriptor's digest")
    func fetchDataAcceptsMatchingContent() async throws {
        let body = Data(#"{"hello":"world"}"#.utf8)
        let digest = SHA256.hash(data: body).digestString
        let descriptor = Descriptor(mediaType: MediaTypes.imageManifest, digest: digest, size: Int64(body.count))

        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: MediaTypes.imageManifest)
            return .status(.ok, headers: headers, body: body)
        }
        defer { Task { try? await server.shutdown() } }

        let client = Self.client(port: server.port)
        let fetched = try await client.fetchData(name: Self.repoName, descriptor: descriptor)
        #expect(fetched == body)
    }

    @Test("fetch<T> rejects a body that doesn't hash to the descriptor's digest, before decoding it")
    func fetchRejectsContentDigestMismatch() async throws {
        let body = Data(#"{"hello":"attacker"}"#.utf8)
        let claimedDigest = "sha256:" + String(repeating: "e", count: 64)  // does not match `body`
        let descriptor = Descriptor(mediaType: MediaTypes.imageManifest, digest: claimedDigest, size: Int64(body.count))

        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: MediaTypes.imageManifest)
            return .status(.ok, headers: headers, body: body)
        }
        defer { Task { try? await server.shutdown() } }

        let client = Self.client(port: server.port)
        await #expect(throws: (any Error).self) {
            let _: DummyPayload = try await client.fetch(name: Self.repoName, descriptor: descriptor)
        }
    }

    @Test("fetchBlob(into:) rejects downloaded content that doesn't hash to the descriptor's digest")
    func fetchBlobIntoFileRejectsContentDigestMismatch() async throws {
        let body = Data(#"{"hello":"attacker"}"#.utf8)
        let claimedDigest = "sha256:" + String(repeating: "f", count: 64)  // does not match `body`
        let descriptor = Descriptor(mediaType: MediaTypes.imageLayerGzip, digest: claimedDigest, size: Int64(body.count))

        let server = try await MockRegistryServer(eventLoopGroup: Self.group) { request in
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: MediaTypes.imageLayerGzip)
            return .status(.ok, headers: headers, body: body)
        }
        defer { Task { try? await server.shutdown() } }

        let client = Self.client(port: server.port)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        await #expect(throws: (any Error).self) {
            _ = try await client.fetchBlob(name: Self.repoName, descriptor: descriptor, into: tempFile, progress: nil)
        }
    }
}
