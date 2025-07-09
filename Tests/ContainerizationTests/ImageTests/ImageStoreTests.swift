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

import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Crypto
import Foundation
import NIOCore
import Testing

@testable import Containerization

// Test-specific extension to expose ExportOperation for testing
extension ImageStore {
    func testPush(reference: String, client: ContentClient, platform: Platform? = nil) async throws {
        let matcher = createPlatformMatcher(for: platform)
        let img = try await self.get(reference: reference)
        let allowedMediaTypes = [MediaTypes.dockerManifestList, MediaTypes.index]
        guard allowedMediaTypes.contains(img.mediaType) else {
            throw ContainerizationError(.internalError, message: "Cannot push image \(reference) with Index media type \(img.mediaType)")
        }
        let ref = try Reference.parse(reference)
        let name = ref.path
        guard let tag = ref.tag ?? ref.digest else {
            throw ContainerizationError(.invalidArgument, message: "Invalid tag/digest for image reference \(reference)")
        }
        let operation = ExportOperation(name: name, tag: tag, contentStore: self.contentStore, client: client, progress: nil)
        try await operation.export(index: img.descriptor, platforms: matcher)
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
        guard descriptor.digest == "sha256:\(actualDigest.encoded)" else {
            throw ContainerizationError(.invalidArgument, message: "Digest mismatch: expected \(descriptor.digest), got sha256:\(actualDigest.encoded)")
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
            await progress([ProgressEvent(event: "add-size", value: Int64(data.count))])
        }
    }
}



@Suite
public class ImageStoreTests: ContainsAuth {
    let store: ImageStore
    let dir: URL

    public init() {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        let cs = try! LocalContentStore(path: dir)
        let store = try! ImageStore(path: dir, contentStore: cs)
        self.dir = dir
        self.store = store
    }

    deinit {
        try! FileManager.default.removeItem(at: self.dir)
    }

    @Test func testImageStoreOperation() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.uniqueTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        let tarPath = Foundation.Bundle.module.url(forResource: "scratch", withExtension: "tar")!
        let reader = try ArchiveReader(format: .pax, filter: .none, file: tarPath)
        try reader.extractContents(to: tempDir)

        let _ = try await self.store.load(from: tempDir)
        let loaded = try await self.store.load(from: tempDir)
        let expectedLoadedImage = "registry.local/integration-tests/scratch:latest"
        #expect(loaded.first!.reference == "registry.local/integration-tests/scratch:latest")

        guard let authentication = Self.authentication else {
            return
        }
        let imageReference = "ghcr.io/apple/containerization/dockermanifestimage:0.0.2"
        let busyboxImage = try await self.store.pull(reference: imageReference, auth: authentication)

        let got = try await self.store.get(reference: imageReference)
        #expect(got.descriptor == busyboxImage.descriptor)

        let newTag = "registry.local/integration-tests/dockermanifestimage:latest"
        let _ = try await self.store.tag(existing: imageReference, new: newTag)

        let tempFile = self.dir.appending(path: "export.tar")
        try await self.store.save(references: [imageReference, expectedLoadedImage], out: tempFile)
    }

    @Test func testImageStorePushWithMock() async throws {
        // Load a test image first to have something to push
        let tarPath = Foundation.Bundle.module.url(forResource: "scratch", withExtension: "tar")!
        let reader = try ArchiveReader(format: .pax, filter: .none, file: tarPath)
        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try reader.extractContents(to: tempDir)

        let loadedImages = try await self.store.load(from: tempDir)
        let testImage = loadedImages.first!

        // Create a mock client to simulate registry interactions
        let mockClient = MockRegistryClient()

        // Tag the image with a test registry reference
        let testReference = "test-registry.local/test-image:latest"
        try await self.store.tag(existing: testImage.reference, new: testReference)

        // Get the actual image to verify layer count
        let actualImage = try await self.store.get(reference: testReference)
        let expectedDigests = actualImage.referencedDigests()

        // Test push with mock client (using extension method)
        try await self.store.testPush(reference: testReference, client: mockClient)

        // Verify that push operations were called
        #expect(!mockClient.pushCalls.isEmpty)

        // Verify that the correct image name and tag were used
        let pushCall = mockClient.pushCalls.first!
        #expect(pushCall.name == "test-registry.local/test-image")
        #expect(pushCall.ref == "latest")
        
        // Verify that all layers of the test image have been pushed
        #expect(mockClient.pushCalls.count == expectedDigests.count)
    }
}
