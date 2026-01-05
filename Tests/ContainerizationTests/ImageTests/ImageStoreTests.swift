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

    @Test func testLoadImageWithoutAnnotations() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.uniqueTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        let tarPath = Foundation.Bundle.module.url(forResource: "scratch_no_annotations", withExtension: "tar")!
        let reader = try ArchiveReader(format: .pax, filter: .none, file: tarPath)
        try reader.extractContents(to: tempDir)

        let loaded = try await self.store.load(from: tempDir)

        #expect(loaded.count == 1)

        let reference = loaded.first!.reference
        #expect(reference.hasPrefix("untagged@sha256:"))

        let retrieved = try await self.store.get(reference: reference)
        #expect(retrieved.reference == reference)
    }
}
