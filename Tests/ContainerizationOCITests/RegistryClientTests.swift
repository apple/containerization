//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

//

import ContainerizationError
import ContainerizationIO
import Crypto
import Foundation
import NIO
import NIOCore
import Synchronization
import Testing

@testable import ContainerizationOCI

struct OCIClientTests: ~Copyable {
    private var contentPath: URL
    private let fileManager = FileManager.default
    private var encoder = JSONEncoder()

    init() async throws {
        let testDir = fileManager.uniqueTemporaryDirectory()
        let contentPath = testDir.appendingPathComponent("content")
        try fileManager.createDirectory(at: contentPath, withIntermediateDirectories: true)
        self.contentPath = contentPath

        encoder.outputFormatting = .prettyPrinted
    }

    deinit {
        try? fileManager.removeItem(at: contentPath)
    }

    private static var arch: String? {
        var uts = utsname()
        let result = uname(&uts)
        guard result == EXIT_SUCCESS else {
            return nil
        }

        let machine = Data(bytes: &uts.machine, count: 256)
        guard let arch = String(bytes: machine, encoding: .utf8) else {
            return nil
        }

        switch arch.lowercased().trimmingCharacters(in: .controlCharacters) {
        case "arm64":
            return "arm64"
        default:
            return "amd64"
        }
    }

    @Test(.enabled(if: hasRegistryCredentials))
    func fetchToken() async throws {
        let client = RegistryClient(host: "ghcr.io", authentication: Self.authentication)
        let request = TokenRequest(realm: "https://ghcr.io/token", service: "ghcr.io", clientId: "tests", scope: nil)
        let response = try await client.fetchToken(request: request)
        #expect(response.getToken() != nil)
    }

    @Test(arguments: [
        "registry-1.docker.io",
        "public.ecr.aws",
        "registry.k8s.io",
        "mcr.microsoft.com",
    ])
    func ping(host: String) async throws {
        let client = RegistryClient(host: host)
        try await client.ping()
    }

    @Test func pingWithInvalidCredentials() async throws {
        let authentication = BasicAuthentication(username: "foo", password: "bar")
        let client = RegistryClient(host: "ghcr.io", authentication: authentication)
        let error = await #expect(throws: RegistryClient.Error.self) { try await client.ping() }
        guard case .invalidStatus(_, let status, let reason) = error else {
            throw error!
        }
        #expect(status == .unauthorized)
        #expect(reason == "Access denied or wrong credentials")
    }

    @Test(.enabled(if: hasRegistryCredentials))
    func pingWithCredentials() async throws {
        let client = RegistryClient(host: "ghcr.io", authentication: Self.authentication)
        try await client.ping()
    }

    @Test func resolve() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        #expect(descriptor.mediaType == MediaTypes.dockerManifest)
        #expect(descriptor.size != 0)
        #expect(!descriptor.digest.isEmpty)
    }

    @Test func resolveSha() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(
            name: "apple/containerization/dockermanifestimage", tag: "sha256:c8d344d228b7d9a702a95227438ec0d71f953a9a483e28ffabc5704f70d2b61e")
        let namedDescriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        #expect(descriptor == namedDescriptor)
        #expect(descriptor.mediaType == MediaTypes.dockerManifest)
        #expect(descriptor.size != 0)
        #expect(!descriptor.digest.isEmpty)
    }

    @Test func fetchManifest() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.layers.count == 1)
    }

    @Test func fetchManifestAsData() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifestData = try await client.fetchData(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        let checksum = SHA256.hash(data: manifestData)
        #expect(descriptor.digest == checksum.digest)
    }

    @Test func fetchConfig() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        let image: Image = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: manifest.config)
        // This is an empty image -- check that the image label is present in the image config
        #expect(image.config?.labels?["org.opencontainers.image.source"] == "https://github.com/apple/containerization")
        #expect(image.rootfs.diffIDs.count == 1)
    }

    @Test func fetchBlob() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        var called = false
        var done = false
        try await client.fetchBlob(name: "apple/containerization/dockermanifestimage", descriptor: manifest.layers.first!) { (expected, body) in
            called = true
            #expect(expected != 0)
            var received = 0
            for try await buffer in body {
                received += buffer.readableBytes
                if received == expected {
                    done = true
                }
            }
        }
        #expect(called)
        #expect(done)
    }

    @Test func pushIndexWithMock() async throws {
        // Create a mock client for testing push operations
        let mockClient = MockRegistryClient()

        // Create test data for an index and its components
        let testLayerData = "test layer content".data(using: .utf8)!
        let layerDigest = SHA256.hash(data: testLayerData)
        let layerDescriptor = Descriptor(
            mediaType: "application/vnd.docker.image.rootfs.diff.tar.gzip",
            digest: "sha256:\(layerDigest.hexString)",
            size: Int64(testLayerData.count)
        )

        // Create test image config
        let imageConfig = Image(
            architecture: "amd64",
            os: "linux",
            config: ImageConfig(labels: ["test": "value"]),
            rootfs: Rootfs(type: "layers", diffIDs: ["sha256:\(layerDigest.hexString)"])
        )
        let configData = try JSONEncoder().encode(imageConfig)
        let configDigest = SHA256.hash(data: configData)
        let configDescriptor = Descriptor(
            mediaType: "application/vnd.docker.container.image.v1+json",
            digest: "sha256:\(configDigest.hexString)",
            size: Int64(configData.count)
        )

        // Create test manifest
        let manifest = Manifest(
            schemaVersion: 2,
            mediaType: "application/vnd.docker.distribution.manifest.v2+json",
            config: configDescriptor,
            layers: [layerDescriptor]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestDigest = SHA256.hash(data: manifestData)
        let manifestDescriptor = Descriptor(
            mediaType: "application/vnd.docker.distribution.manifest.v2+json",
            digest: "sha256:\(manifestDigest.hexString)",
            size: Int64(manifestData.count),
            platform: Platform(arch: "amd64", os: "linux")
        )

        // Create test index
        let index = Index(
            schemaVersion: 2,
            mediaType: "application/vnd.docker.distribution.manifest.list.v2+json",
            manifests: [manifestDescriptor]
        )

        let name = "test/image"
        let ref = "latest"

        // Test pushing individual components using the mock client

        // Push layer
        let layerStream = TestByteBufferSequence(data: testLayerData)
        try await mockClient.push(
            name: name,
            ref: ref,
            descriptor: layerDescriptor,
            streamGenerator: { layerStream },
            progress: nil as ProgressHandler?
        )

        // Push config
        let configStream = TestByteBufferSequence(data: configData)
        try await mockClient.push(
            name: name,
            ref: ref,
            descriptor: configDescriptor,
            streamGenerator: { configStream },
            progress: nil as ProgressHandler?
        )

        // Push manifest
        let manifestStream = TestByteBufferSequence(data: manifestData)
        try await mockClient.push(
            name: name,
            ref: ref,
            descriptor: manifestDescriptor,
            streamGenerator: { manifestStream },
            progress: nil as ProgressHandler?
        )

        // Push index
        let indexData = try JSONEncoder().encode(index)
        let indexDigest = SHA256.hash(data: indexData)
        let indexDescriptor = Descriptor(
            mediaType: "application/vnd.docker.distribution.manifest.list.v2+json",
            digest: "sha256:\(indexDigest.hexString)",
            size: Int64(indexData.count)
        )

        let indexStream = TestByteBufferSequence(data: indexData)
        try await mockClient.push(
            name: name,
            ref: ref,
            descriptor: indexDescriptor,
            streamGenerator: { indexStream },
            progress: nil as ProgressHandler?
        )

        // Verify all push operations were recorded
        #expect(mockClient.pushCalls.count == 4)

        // Verify content integrity
        let storedLayerData = mockClient.getPushedContent(name: name, descriptor: layerDescriptor)
        #expect(storedLayerData == testLayerData)

        let storedConfigData = mockClient.getPushedContent(name: name, descriptor: configDescriptor)
        #expect(storedConfigData == configData)

        let storedManifestData = mockClient.getPushedContent(name: name, descriptor: manifestDescriptor)
        #expect(storedManifestData == manifestData)

        let storedIndexData = mockClient.getPushedContent(name: name, descriptor: indexDescriptor)
        #expect(storedIndexData == indexData)
    }

    @Test func resolveWithRetry() async throws {
        let counter = Mutex(0)
        let client = RegistryClient(
            host: "ghcr.io",
            retryOptions: RetryOptions(
                maxRetries: 3,
                retryInterval: 500_000_000,
                shouldRetry: ({ response in
                    if response.status == .notFound {
                        counter.withLock { $0 += 1 }
                        return true
                    }
                    return false
                })
            )
        )
        do {
            _ = try await client.resolve(name: "containerization/not-exists", tag: "foo")
        } catch {
            #expect(counter.withLock { $0 } <= 3)
        }
    }

    // MARK: private functions

    static var hasRegistryCredentials: Bool {
        authentication != nil
    }

    static var authentication: Authentication? {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["REGISTRY_TOKEN"],
            let username = env["REGISTRY_USERNAME"]
        else {
            return nil
        }
        return BasicAuthentication(username: username, password: password)
    }

    @discardableResult
    private func pushDescriptor<T: Encodable>(
        client: RegistryClient,
        name: String,
        ref: String,
        content: T,
        baseDescriptor: Descriptor
    ) async throws -> Descriptor {
        let encoded = try self.encoder.encode(content)
        let digest = SHA256.hash(data: encoded)
        let descriptor = Descriptor(
            mediaType: baseDescriptor.mediaType,
            digest: digest.digest,
            size: Int64(encoded.count),
            urls: baseDescriptor.urls,
            annotations: baseDescriptor.annotations,
            platform: baseDescriptor.platform
        )
        let generator = {
            let stream = ReadStream(data: encoded)
            try stream.reset()
            return stream.stream
        }

        try await client.push(
            name: name,
            ref: ref,
            descriptor: descriptor,
            streamGenerator: generator,
            progress: nil as ProgressHandler?
        )
        return descriptor
    }
}

extension OutputStream {
    fileprivate func withThrowingOpeningStream(_ closure: () async throws -> Void) async throws {
        self.open()
        defer { self.close() }

        try await closure()
    }
}

extension SHA256.Digest {
    fileprivate var digest: String {
        let parts = self.description.split(separator: ": ")
        return "sha256:\(parts[1])"
    }

    var hexString: String {
        self.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// Helper to create ByteBuffer sequences for testing
struct TestByteBufferSequence: Sendable, AsyncSequence {
    typealias Element = ByteBuffer

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(data: data)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        private let data: Data
        private var sent = false

        init(data: Data) {
            self.data = data
        }

        mutating func next() async throws -> ByteBuffer? {
            guard !sent else { return nil }
            sent = true

            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            return buffer
        }
    }
}

// Helper class to create a mock ContentClient for testing
final class MockRegistryClient: ContentClient, @unchecked Sendable {
    private var pushedContent: [String: [Descriptor: Data]] = [:]
    private var fetchableContent: [String: [Descriptor: Data]] = [:]

    // Track push operations for verification
    var pushCalls: [(name: String, ref: String, descriptor: Descriptor)] = []

    func addFetchableContent<T: Codable>(name: String, descriptor: Descriptor, content: T) throws {
        let data = try JSONEncoder().encode(content)
        if fetchableContent[name] == nil {
            fetchableContent[name] = [:]
        }
        fetchableContent[name]![descriptor] = data
    }

    func addFetchableData(name: String, descriptor: Descriptor, data: Data) {
        if fetchableContent[name] == nil {
            fetchableContent[name] = [:]
        }
        fetchableContent[name]![descriptor] = data
    }

    func getPushedContent(name: String, descriptor: Descriptor) -> Data? {
        pushedContent[name]?[descriptor]
    }

    // MARK: - ContentClient Implementation

    func fetch<T: Codable>(name: String, descriptor: Descriptor) async throws -> T {
        guard let imageContent = fetchableContent[name],
            let data = imageContent[descriptor]
        else {
            throw ContainerizationError(.notFound, message: "Content not found for \(name) with descriptor \(descriptor.digest)")
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchBlob(name: String, descriptor: Descriptor, into file: URL, progress: ProgressHandler?) async throws -> (Int64, SHA256.Digest) {
        guard let imageContent = fetchableContent[name],
            let data = imageContent[descriptor]
        else {
            throw ContainerizationError(.notFound, message: "Blob not found for \(name) with descriptor \(descriptor.digest)")
        }

        try data.write(to: file)
        let digest = SHA256.hash(data: data)
        return (Int64(data.count), digest)
    }

    func fetchData(name: String, descriptor: Descriptor) async throws -> Data {
        guard let imageContent = fetchableContent[name],
            let data = imageContent[descriptor]
        else {
            throw ContainerizationError(.notFound, message: "Data not found for \(name) with descriptor \(descriptor.digest)")
        }

        return data
    }

    func push<T: Sendable & AsyncSequence>(
        name: String,
        ref: String,
        descriptor: Descriptor,
        streamGenerator: () throws -> T,
        progress: ProgressHandler?
    ) async throws where T.Element == ByteBuffer {
        // Record the push call for verification
        pushCalls.append((name: name, ref: ref, descriptor: descriptor))

        // Simulate reading the stream and storing the data
        let stream = try streamGenerator()
        var data = Data()

        for try await buffer in stream {
            data.append(contentsOf: buffer.readableBytesView)
        }

        // Verify the pushed data matches the expected descriptor
        let actualDigest = SHA256.hash(data: data)
        guard descriptor.digest == "sha256:\(actualDigest.hexString)" else {
            throw ContainerizationError(.invalidArgument, message: "Digest mismatch: expected \(descriptor.digest), got sha256:\(actualDigest.hexString)")
        }

        guard data.count == descriptor.size else {
            throw ContainerizationError(.invalidArgument, message: "Size mismatch: expected \(descriptor.size), got \(data.count)")
        }

        // Store the pushed content
        if pushedContent[name] == nil {
            pushedContent[name] = [:]
        }
        pushedContent[name]![descriptor] = data

        // Simulate progress reporting
        if let progress = progress {
            await progress(Int64(data.count), Int64(data.count))
        }
    }
}
