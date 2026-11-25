//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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
import Foundation
import Testing

@testable import Containerization

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
        let rejectedPaths = try reader.extractContents(to: tempDir)
        #expect(rejectedPaths.count == 0, "unexpected rejected paths [\(rejectedPaths)]")

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

    @Test(.disabled("External users cannot push images, disable while we find a better solution"))
    func testImageStorePush() async throws {
        guard let authentication = Self.authentication else {
            return
        }
        let imageReference = "ghcr.io/apple/containerization/dockermanifestimage:0.0.2"

        let remoteImageName = "ghcr.io/apple/test-images/image-push"
        let epoch = Int(Date().timeIntervalSince1970.description)
        let tag = epoch != nil ? String(epoch!) : "latest"
        let upstreamTag = "\(remoteImageName):\(tag)"
        let _ = try await self.store.tag(existing: imageReference, new: upstreamTag)
        try await self.store.push(reference: upstreamTag, auth: authentication)
    }

    @Test(.disabled("External users cannot push images, disable while we find a better solution"))
    func testImageStorePushMultipleReferences() async throws {
        guard let authentication = Self.authentication else {
            return
        }
        let imageReference = "ghcr.io/apple/containerization/dockermanifestimage:0.0.2"

        let remoteImageName = "ghcr.io/apple/test-images/image-push"
        let epoch = Int(Date().timeIntervalSince1970)
        let tags = ["\(remoteImageName):\(epoch)-a", "\(remoteImageName):\(epoch)-b", "\(remoteImageName):\(epoch)-c"]
        for tag in tags {
            let _ = try await self.store.tag(existing: imageReference, new: tag)
        }
        try await self.store.push(references: tags, auth: authentication, maxConcurrentUploads: 2)
    }

    @Test func testLoadImageWithoutAnnotations() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.uniqueTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        let tarPath = Foundation.Bundle.module.url(forResource: "scratch_no_annotations", withExtension: "tar")!
        let reader = try ArchiveReader(format: .pax, filter: .none, file: tarPath)
        let rejectedPaths = try reader.extractContents(to: tempDir)
        #expect(rejectedPaths.count == 0, "unexpected rejected paths [\(rejectedPaths)]")

        let loaded = try await self.store.load(from: tempDir)

        #expect(loaded.count == 1)

        let reference = loaded.first!.reference
        #expect(reference.hasPrefix("untagged@sha256:"))

        let retrieved = try await self.store.get(reference: reference)
        #expect(retrieved.reference == reference)
    }

    // Digests of the manifests listed by the index in scratch.tar.
    private static let scratchArm64Manifest = "872d74070f985083ac362527084460ff5a21815dfabd6e8de8baf677206340ee"
    private static let scratchAmd64Manifest = "3f2b0792ca7c9418ca2483c03bef2e3d3ea23205d0add5bd5cc55cdbc993027e"
    private static let scratchAttestationManifests = [
        "31191d9dccfa844f1e7e9e8dbca4e226e373404e459fa9fe9344c8f5cb18c21b",
        "cf9289c9a9cb3e926973c9d9668bf8faa5ec559157e03b4710324220e70da360",
    ]

    private func extractScratch(removing digests: [String]) throws -> URL {
        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        let tarPath = Foundation.Bundle.module.url(forResource: "scratch", withExtension: "tar")!
        let reader = try ArchiveReader(format: .pax, filter: .none, file: tarPath)
        let rejectedPaths = try reader.extractContents(to: tempDir)
        #expect(rejectedPaths.count == 0, "unexpected rejected paths [\(rejectedPaths)]")
        for digest in digests {
            try FileManager.default.removeItem(at: tempDir.appending(path: "blobs/sha256/\(digest)"))
        }
        return tempDir
    }

    @Test func testLoadIndexWithAbsentPlatformManifests() async throws {
        // Mimic an archive saved for a single platform, but that still carries the full index.
        let tempDir = try extractScratch(removing: [Self.scratchAmd64Manifest] + Self.scratchAttestationManifests)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let loaded = try await self.store.load(from: tempDir)
        #expect(loaded.count == 1)

        // The index is preserved as is, and the content that was present is usable.
        let image = try await self.store.get(reference: "registry.local/integration-tests/scratch:latest")
        let index = try await image.index()
        #expect(index.manifests.count == 4)
        let arm64 = ContainerizationOCI.Platform(arch: "arm64", os: "linux")
        _ = try await image.manifest(for: arm64)
    }

    @Test func testLoadIndexWithNoPresentPlatformManifests() async throws {
        let tempDir = try extractScratch(removing: [Self.scratchArm64Manifest, Self.scratchAmd64Manifest] + Self.scratchAttestationManifests)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let error = await #expect(throws: ContainerizationError.self) {
            _ = try await self.store.load(from: tempDir)
        }
        let message = error?.description ?? ""
        #expect(message.contains("linux/arm64"), "\(message)")
        #expect(message.contains("linux/amd64"), "\(message)")
        #expect(message.contains(Self.scratchAmd64Manifest), "\(message)")
    }

    @Test func testGetOrNilMissingReference() async throws {
        #expect(try await self.store.getOrNil(reference: "registry.local/missing:latest") == nil)
    }

    @Test func testConcurrentCreateAcrossTwoStoreInstances() async throws {
        let other = try ImageStore(path: self.dir, contentStore: try LocalContentStore(path: self.dir))
        let descriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: "sha256:" + String(repeating: "0", count: 64),
            size: 0
        )
        let count = 100

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (prefix, store) in [("a", self.store), ("b", other)] {
                group.addTask {
                    for i in 0..<count {
                        try await store.create(
                            description: Image.Description(
                                reference: "registry.local/\(prefix)-\(i):latest",
                                descriptor: descriptor
                            )
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        let expected = Set(
            (0..<count).flatMap { i in
                ["registry.local/a-\(i):latest", "registry.local/b-\(i):latest"]
            }
        )
        let refsFromPrimary = Set(try await self.store.list().map(\.reference))
        let refsFromOther = Set(try await other.list().map(\.reference))
        #expect(refsFromPrimary == expected)
        #expect(refsFromOther == expected)
    }

    @Test func testConcurrentCreateAndDeleteAcrossTwoStoreInstances() async throws {
        let other = try ImageStore(path: self.dir, contentStore: try LocalContentStore(path: self.dir))
        let descriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: "sha256:" + String(repeating: "1", count: 64),
            size: 0
        )
        let count = 50

        for i in 0..<count {
            try await self.store.create(
                description: Image.Description(
                    reference: "registry.local/delete-\(i):latest",
                    descriptor: descriptor
                )
            )
        }

        let primary = self.store
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<count {
                    try await primary.delete(reference: "registry.local/delete-\(i):latest")
                }
            }
            group.addTask {
                for i in 0..<count {
                    try await other.create(
                        description: Image.Description(
                            reference: "registry.local/keep-\(i):latest",
                            descriptor: descriptor
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        let expected = Set((0..<count).map { "registry.local/keep-\($0):latest" })
        let remaining = Set(try await self.store.list().map(\.reference))
        #expect(remaining == expected)
    }

    @Test func testCleanUpOrphanedBlobsPreservesConcurrentlyLoadedImage() async throws {
        let fileManager = FileManager.default
        let scratchDir = fileManager.uniqueTemporaryDirectory()
        let baseDir = fileManager.uniqueTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: scratchDir)
            try? fileManager.removeItem(at: baseDir)
        }

        let scratchTar = try #require(Foundation.Bundle.module.url(forResource: "scratch", withExtension: "tar"))
        let baseTar = try #require(Foundation.Bundle.module.url(forResource: "scratch_no_annotations", withExtension: "tar"))

        let scratchRejected = try ArchiveReader(format: .pax, filter: .none, file: scratchTar).extractContents(to: scratchDir)
        #expect(scratchRejected.isEmpty)
        let baseRejected = try ArchiveReader(format: .pax, filter: .none, file: baseTar).extractContents(to: baseDir)
        #expect(baseRejected.isEmpty)

        let baseLoaded = try await self.store.load(from: baseDir)
        let baseReference = try #require(baseLoaded.first?.reference)

        let other = try ImageStore(path: self.dir, contentStore: try LocalContentStore(path: self.dir))
        let tagCount = 100
        let scratchReference = "registry.local/integration-tests/scratch:latest"

        let primary = self.store
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<tagCount {
                    _ = try await other.tag(existing: baseReference, new: "registry.local/tag-\(i):latest")
                }
            }
            group.addTask {
                let loaded = try await primary.load(from: scratchDir)
                #expect(loaded.first?.reference == scratchReference)
            }
            try await group.waitForAll()
        }

        let allRefs = Set(try await self.store.list().map(\.reference))
        #expect(allRefs.contains(scratchReference))
        #expect(allRefs.contains(baseReference))
        for i in 0..<tagCount {
            #expect(allRefs.contains("registry.local/tag-\(i):latest"))
        }

        let (deleted, freed) = try await self.store.cleanUpOrphanedBlobs()
        #expect(deleted.isEmpty)
        #expect(freed == 0)

        let scratchImage = try await self.store.get(reference: scratchReference)
        let index = try await scratchImage.index()
        #expect(index.manifests.count == 4)
    }
}
