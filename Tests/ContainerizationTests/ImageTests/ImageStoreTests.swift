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
}
