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

/// Registry and OCI layout JSON is the trust boundary for descriptor digests.
/// Rejecting a malformed digest here is what stops one from being written into
/// the local store and dereferenced later.
@Suite
struct DescriptorDecodingTests {
    private static let valid = "sha256:\(String(repeating: "a", count: 64))"
    private static let traversal = "sha256:../../../../etc/hosts"

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
    }

    @Test func acceptsCanonicalDescriptor() throws {
        let json = """
            {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(Self.valid)","size":1234}
            """
        let decoded = try decode(Descriptor.self, json)
        #expect(decoded.digest == Self.valid)
        #expect(decoded.size == 1234)
    }

    @Test(arguments: [
        "sha256:../../../../etc/hosts",
        "../../etc/hosts",
        "sha256:",
        "",
        "sha256:\(String(repeating: "a", count: 63))",
        "sha256:\(String(repeating: "A", count: 64))",
        "sha512:\(String(repeating: "a", count: 128))",
        "\(String(repeating: "a", count: 64))",
    ])
    func rejectsMalformedDescriptorDigest(_ digest: String) throws {
        let json = """
            {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(digest)","size":1}
            """
        #expect(throws: DecodingError.self) {
            try decode(Descriptor.self, json)
        }
    }

    @Test func rejectsNegativeSize() throws {
        let json = """
            {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(Self.valid)","size":-1}
            """
        // A negative size flips the small/large blob branch during import and
        // corrupts progress accounting.
        #expect(throws: DecodingError.self) {
            try decode(Descriptor.self, json)
        }
    }

    @Test func rejectsIndexWithTraversingChild() throws {
        // This is the shape that matters: the index itself is content addressed
        // and verifiable, but a child entry for a platform the caller did not
        // ask for is never fetched, so nothing else would ever check it.
        let json = """
            {
                "schemaVersion": 2,
                "manifests": [
                    {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(Self.valid)","size":10,
                     "platform":{"architecture":"arm64","os":"linux"}},
                    {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(Self.traversal)","size":10,
                     "platform":{"architecture":"ppc64le","os":"linux"}}
                ]
            }
            """
        #expect(throws: DecodingError.self) {
            try decode(Index.self, json)
        }
    }

    @Test func rejectsIndexWithTraversingSubject() throws {
        let json = """
            {"schemaVersion":2,"manifests":[],
             "subject":{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(Self.traversal)","size":1}}
            """
        #expect(throws: DecodingError.self) {
            try decode(Index.self, json)
        }
    }

    @Test func rejectsManifestWithTraversingConfig() throws {
        let json = """
            {"schemaVersion":2,
             "config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"\(Self.traversal)","size":2},
             "layers":[]}
            """
        #expect(throws: DecodingError.self) {
            try decode(Manifest.self, json)
        }
    }

    @Test func rejectsManifestWithTraversingLayer() throws {
        let json = """
            {"schemaVersion":2,
             "config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"\(Self.valid)","size":2},
             "layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"\(Self.traversal)","size":3}]}
            """
        #expect(throws: DecodingError.self) {
            try decode(Manifest.self, json)
        }
    }

    @Test func roundTripsThroughEncoder() throws {
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: Self.valid,
            size: 512,
            annotations: ["org.opencontainers.image.title": "metadata.json"])
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(Descriptor.self, from: data)
        #expect(decoded == descriptor)
    }
}
