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

import ContainerizationExtras
import ContainerizationOCI
@preconcurrency import Crypto
import Foundation
import Testing

@testable import Containerization

@Suite
struct ImageStorePlatformsTests {
    private struct Blob {
        let data: Data
        let digest: SHA256.Digest

        init(_ value: some Encodable) throws {
            self.data = try JSONEncoder().encode(value)
            self.digest = SHA256.hash(data: data)
        }

        func descriptor(_ mediaType: String, platform: Platform? = nil) -> Descriptor {
            Descriptor(mediaType: mediaType, digest: digest.digestString, size: Int64(data.count), platform: platform)
        }
    }

    private static func ingest(_ blobs: [Blob], into store: LocalContentStore) async throws {
        _ = try await store.ingest { dir in
            for blob in blobs {
                try blob.data.write(to: dir.appendingPathComponent(blob.digest.encoded))
            }
        }
    }

    @Test func localIndexNeedsNoRegistry() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
        }
        let contentStore = try LocalContentStore(path: dir)
        let store = try ImageStore(path: dir, contentStore: contentStore)

        let digest = "sha256:" + String(repeating: "0", count: 64)
        let linux = Platform(arch: "arm64", os: "linux", variant: "v8")
        let windows = Platform(arch: "amd64", os: "windows")
        let index = try Blob(
            Index(manifests: [
                Descriptor(mediaType: MediaTypes.imageManifest, digest: digest, size: 1, platform: linux),
                Descriptor(mediaType: MediaTypes.imageManifest, digest: digest, size: 1, platform: windows),
            ]))
        try await Self.ingest([index], into: contentStore)

        // Unresolvable host proves no registry call is made.
        let reference = "registry.invalid/test/multi:latest"
        _ = try await store.create(
            description: Containerization.Image.Description(reference: reference, descriptor: index.descriptor(MediaTypes.index)))

        #expect(try await store.platforms(reference: reference) == [linux, windows])
    }

    @Test func singleManifestUsesConfig() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
        }
        let contentStore = try LocalContentStore(path: dir)

        let config = try Blob(
            ContainerizationOCI.Image(architecture: "amd64", os: "windows", rootfs: Rootfs(type: "layers", diffIDs: [])))
        let manifest = try Blob(Manifest(config: config.descriptor(MediaTypes.imageConfig), layers: []))
        try await Self.ingest([config, manifest], into: contentStore)
        let client = try LocalOCILayoutClient(root: dir)

        let platforms = try await ImageStore.platforms(root: manifest.descriptor(MediaTypes.imageManifest), name: "test/single", client: client)

        #expect(platforms == [Platform(arch: "amd64", os: "windows")])
    }
}
