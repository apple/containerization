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

import Foundation
import Testing

@testable import ContainerizationOCI

struct OCITests {
    /// Descriptor digests are validated when decoded, so fixtures that round trip
    /// through JSON need well formed `sha256:<64 hex>` values.
    private static func digest(_ seed: String) -> String {
        let hex = String(repeating: seed, count: 64).prefix(64)
        return "sha256:\(hex)"
    }

    @Test func config() {
        let config = ContainerizationOCI.ImageConfig()
        let rootfs = ContainerizationOCI.Rootfs(type: "foo", diffIDs: ["diff1", "diff2"])
        let history = ContainerizationOCI.History()

        let image = ContainerizationOCI.Image(architecture: "arm64", os: "linux", config: config, rootfs: rootfs, history: [history])
        #expect(image.rootfs.type == "foo")
    }

    @Test func descriptor() {
        let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux")
        let descriptor = ContainerizationOCI.Descriptor(mediaType: MediaTypes.descriptor, digest: "123", size: 0, platform: platform)

        #expect(descriptor.platform?.architecture == "arm64")
        #expect(descriptor.platform?.os == "linux")
        #expect(descriptor.artifactType == nil)
    }

    @Test func descriptorWithArtifactType() throws {
        let testArtifactType = "application/vnd.example.test.v1+json"
        let descriptor = ContainerizationOCI.Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: Self.digest("abc123"),
            size: 1234,
            artifactType: testArtifactType
        )
        #expect(descriptor.artifactType == testArtifactType)

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(ContainerizationOCI.Descriptor.self, from: data)
        #expect(decoded.artifactType == testArtifactType)
    }

    @Test func descriptorWithoutArtifactTypeDecodesAsNil() throws {
        let json = """
                {"mediaType":"application/vnd.oci.descriptor.v1+json","digest":"\(Self.digest("abc"))","size":0}
            """
        let decoded = try JSONDecoder().decode(ContainerizationOCI.Descriptor.self, from: json.data(using: .utf8)!)
        #expect(decoded.artifactType == nil)
    }

    @Test func index() {
        var descriptors: [ContainerizationOCI.Descriptor] = []
        for i in 0..<5 {
            let descriptor = ContainerizationOCI.Descriptor(mediaType: MediaTypes.descriptor, digest: "\(i)", size: Int64(i))
            descriptors.append(descriptor)
        }

        let index = ContainerizationOCI.Index(schemaVersion: 1, manifests: descriptors)
        #expect(index.manifests.count == 5)
        #expect(index.subject == nil)
        #expect(index.artifactType == nil)
    }

    @Test func indexWithSubjectAndArtifactType() throws {
        let testArtifactType = "application/vnd.example.test.v1+json"
        let subjectDigest = Self.digest("5b")
        let subject = ContainerizationOCI.Descriptor(mediaType: MediaTypes.imageManifest, digest: subjectDigest, size: 512)
        let index = ContainerizationOCI.Index(
            schemaVersion: 2,
            manifests: [],
            subject: subject,
            artifactType: testArtifactType
        )
        #expect(index.subject?.digest == subjectDigest)
        #expect(index.artifactType == testArtifactType)

        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(ContainerizationOCI.Index.self, from: data)
        #expect(decoded.subject?.digest == subjectDigest)
        #expect(decoded.artifactType == testArtifactType)
    }

    @Test func indexDecodesWithoutNewFields() throws {
        let json = """
                {"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.descriptor.v1+json","digest":"\(Self.digest("abc"))","size":10}]}
            """
        let decoded = try JSONDecoder().decode(ContainerizationOCI.Index.self, from: json.data(using: .utf8)!)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.manifests.count == 1)
        #expect(decoded.subject == nil)
        #expect(decoded.artifactType == nil)
    }

    @Test func manifests() {
        var descriptors: [ContainerizationOCI.Descriptor] = []
        for i in 0..<5 {
            let descriptor = ContainerizationOCI.Descriptor(mediaType: MediaTypes.descriptor, digest: "\(i)", size: Int64(i))
            descriptors.append(descriptor)
        }

        let config = ContainerizationOCI.Descriptor(mediaType: MediaTypes.descriptor, digest: "123", size: 0)

        let manifest = ContainerizationOCI.Manifest(schemaVersion: 1, config: config, layers: descriptors)
        #expect(manifest.config.digest == "123")
        #expect(manifest.layers.count == 5)
        #expect(manifest.subject == nil)
        #expect(manifest.artifactType == nil)
    }

    @Test func manifestWithSubjectAndArtifactType() throws {
        let testArtifactType = "application/vnd.example.test.v1+json"
        let targetDigest = Self.digest("7a")
        let config = ContainerizationOCI.Descriptor(mediaType: MediaTypes.emptyJSON, digest: Self.digest("e"), size: 2)
        let subject = ContainerizationOCI.Descriptor(mediaType: MediaTypes.imageManifest, digest: targetDigest, size: 1234)
        let layer = ContainerizationOCI.Descriptor(
            mediaType: testArtifactType,
            digest: Self.digest("3a"),
            size: 89,
            annotations: ["org.opencontainers.image.title": "metadata.json"]
        )

        let manifest = ContainerizationOCI.Manifest(
            config: config,
            layers: [layer],
            subject: subject,
            artifactType: testArtifactType
        )
        #expect(manifest.subject?.digest == targetDigest)
        #expect(manifest.artifactType == testArtifactType)
        #expect(manifest.layers[0].annotations?["org.opencontainers.image.title"] == "metadata.json")

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ContainerizationOCI.Manifest.self, from: data)
        #expect(decoded.subject?.digest == targetDigest)
        #expect(decoded.artifactType == testArtifactType)
    }

    @Test func manifestDecodesWithoutNewFields() throws {
        let json = """
                {
                    "schemaVersion": 2,
                    "config": {"mediaType":"application/vnd.oci.empty.v1+json","digest":"\(Self.digest("abc"))","size":2},
                    "layers": []
                }
            """
        let decoded = try JSONDecoder().decode(ContainerizationOCI.Manifest.self, from: json.data(using: .utf8)!)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.subject == nil)
        #expect(decoded.artifactType == nil)
    }
}
