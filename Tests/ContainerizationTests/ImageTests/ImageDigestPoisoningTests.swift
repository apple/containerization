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

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Crypto
import Foundation
import Testing

@testable import Containerization

/// Regression tests for a registry supplied digest reaching the filesystem.
///
/// A platform specific pull walks an index, drops the entries whose platform does
/// not match, and only then fetches and digest verifies what is left. An entry for
/// a platform the caller never asked for is therefore never content verified, yet
/// the index that lists it is stored and re-read on later operations. These tests
/// pin that a traversing digest cannot survive that path, and that a store already
/// carrying one fails closed rather than reading or deleting outside itself.
@Suite
struct ImageDigestPoisoningTests {
    private static let traversal = "sha256:../../secret.txt"
    private static let healthyIndexJSON = "{\"schemaVersion\":2,\"manifests\":[]}"

    private struct Fixture {
        let dir: URL
        let store: ImageStore
        let contentStore: LocalContentStore
        let sentinel: URL
        let sentinelContents = "do not read me"
    }

    private func makeFixture() throws -> Fixture {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        let cs = try LocalContentStore(path: dir)
        let store = try ImageStore(path: dir, contentStore: cs)

        // Blobs live at <dir>/blobs/sha256, so "../../secret.txt" lands here.
        let sentinel = dir.appendingPathComponent("secret.txt")
        let fixture = Fixture(dir: dir, store: store, contentStore: cs, sentinel: sentinel)
        try Data(fixture.sentinelContents.utf8).write(to: sentinel)
        return fixture
    }

    /// Builds the index a poisoned multi-arch pull would leave behind, using the
    /// memberwise initializer to bypass decode validation the way a store
    /// poisoned before this fix would have.
    private func seedPoisonedImage(_ fixture: Fixture, reference: String) async throws -> Containerization.Image {
        let manifestData = Data("{\"schemaVersion\":2}".utf8)
        let manifestDigest = SHA256.hash(data: manifestData)

        let matching = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest.digestString,
            size: Int64(manifestData.count),
            platform: Platform(arch: "arm64", os: "linux"))
        let poisoned = Descriptor(
            mediaType: "application/vnd.test.opaque.v1+json",
            digest: Self.traversal,
            size: 1,
            platform: Platform(arch: "ppc64le", os: "linux"))

        let index = Index(manifests: [matching, poisoned])
        let indexData = try JSONEncoder().encode(index)
        let indexDigest = SHA256.hash(data: indexData)

        try await fixture.contentStore.ingest { ingestDir in
            try manifestData.write(to: ingestDir.appendingPathComponent(manifestDigest.encoded))
            try indexData.write(to: ingestDir.appendingPathComponent(indexDigest.encoded))
        }

        let indexDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: indexDigest.digestString,
            size: Int64(indexData.count))
        return try await fixture.store.create(
            description: Containerization.Image.Description(reference: reference, descriptor: indexDescriptor))
    }

    @Test func poisonedIndexFailsClosedInsteadOfReadingOutsideTheStore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let image = try await seedPoisonedImage(fixture, reference: "test/poison:v1")

        // The index blob is content addressed and intact, but it lists a digest
        // that cannot be a blob name, so decoding it must fail rather than
        // resolve the traversal.
        await #expect(throws: (any Swift.Error).self) {
            try await image.index()
        }
        await #expect(throws: (any Swift.Error).self) {
            try await image.referencedDigests()
        }

        #expect(FileManager.default.fileExists(atPath: fixture.sentinel.path))
        let contents = try String(contentsOf: fixture.sentinel, encoding: .utf8)
        #expect(contents == fixture.sentinelContents)
    }

    @Test func getContentRejectsTraversingDigest() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let image = try await seedPoisonedImage(fixture, reference: "test/poison:v2")

        // The referencedDigests membership check is not validation: a digest the
        // attacker listed is trivially in its own allow list. The digest itself
        // has to be rejected.
        do {
            _ = try await image.getContent(digest: Self.traversal)
            Issue.record("expected a traversing digest to be rejected")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.sentinel.path))
    }

    /// Garbage collection has to fail closed. If it treated an unreadable index
    /// as "this image references nothing", every blob belonging to it would be
    /// deleted as orphaned.
    @Test func cleanupFailsClosedAndDeletesNothing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try await seedPoisonedImage(fixture, reference: "test/poison:v3")

        let blobs = fixture.dir.appendingPathComponent("blobs/sha256")
        let before = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        #expect(before.count == 2)

        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.cleanUpOrphanedBlobs()
        }

        let after = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        #expect(after == before)
        #expect(FileManager.default.fileExists(atPath: fixture.sentinel.path))
    }

    /// A poisoned index blob must not take the rest of the store down with it.
    @Test func storeRemainsUsableAlongsideAPoisonedRecord() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try await seedPoisonedImage(fixture, reference: "test/poison:v4")
        let healthyDigest = try await seedHealthyImage(fixture, reference: "test/healthy:v1")

        let listed = try await fixture.store.list().map { $0.reference }.sorted()
        #expect(listed.contains("test/healthy:v1"))

        let healthy = try await fixture.store.get(reference: "test/healthy:v1")
        let referenced = try await healthy.referencedDigests()
        #expect(referenced == [healthyDigest.encoded])
    }

    /// The state file is decoded per record, so a record whose own descriptor
    /// digest is malformed is skipped instead of making every image in the store
    /// unreachable. Without this, adding decode validation would turn a poisoned
    /// or legacy record into a total outage: listing, pulling and deleting all
    /// load this file.
    @Test func stateFileSkipsUnreadableRecords() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let healthyDigest = try await seedHealthyImage(fixture, reference: "test/healthy:v1")

        let state = """
            {
              "test/healthy:v1": {"mediaType":"application/vnd.oci.image.index.v1+json","digest":"\(healthyDigest.digestString)","size":\(Self.healthyIndexJSON.utf8.count)},
              "test/broken:v1": {"mediaType":"application/vnd.oci.image.index.v1+json","digest":"\(Self.traversal)","size":1}
            }
            """
        try Data(state.utf8).write(to: fixture.dir.appendingPathComponent("state.json"))

        let listed = try await fixture.store.list().map { $0.reference }
        #expect(listed == ["test/healthy:v1"])

        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.get(reference: "test/broken:v1")
        }
    }

    /// An unreadable manifest must not be treated as a childless one. If it were,
    /// its layers would be missing from the keep set and garbage collection would
    /// delete the live blobs of a healthy image.
    @Test func oversizedManifestDoesNotSilentlyDropItsLayers() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        // A syntactically valid manifest that exceeds the decode limit, padded via
        // an annotation so it stays parseable JSON.
        let padding = String(repeating: "0", count: LocalContent.maxDecodedSize)
        let layerData = Data("layer".utf8)
        let layerDigest = SHA256.hash(data: layerData)
        let configData = Data("config".utf8)
        let configDigest = SHA256.hash(data: configData)
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: configDigest.digestString, size: Int64(configData.count)),
            layers: [Descriptor(mediaType: MediaTypes.imageLayer, digest: layerDigest.digestString, size: Int64(layerData.count))],
            annotations: ["pad": padding])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestDigest = SHA256.hash(data: manifestData)
        #expect(manifestData.count > LocalContent.maxDecodedSize)

        let index = Index(manifests: [
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: manifestDigest.digestString,
                size: Int64(manifestData.count),
                platform: Platform(arch: "arm64", os: "linux"))
        ])
        let indexData = try JSONEncoder().encode(index)
        let indexDigest = SHA256.hash(data: indexData)

        try await fixture.contentStore.ingest { ingestDir in
            try layerData.write(to: ingestDir.appendingPathComponent(layerDigest.encoded))
            try configData.write(to: ingestDir.appendingPathComponent(configDigest.encoded))
            try manifestData.write(to: ingestDir.appendingPathComponent(manifestDigest.encoded))
            try indexData.write(to: ingestDir.appendingPathComponent(indexDigest.encoded))
        }

        let image = try await fixture.store.create(
            description: Containerization.Image.Description(
                reference: "test/oversized:v1",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: indexDigest.digestString,
                    size: Int64(indexData.count))))

        // Fail closed rather than report an incomplete keep set.
        await #expect(throws: (any Swift.Error).self) {
            try await image.referencedDigests()
        }

        let blobs = fixture.dir.appendingPathComponent("blobs/sha256")
        let before = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.cleanUpOrphanedBlobs()
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        #expect(after == before)
        #expect(after.contains(layerDigest.encoded))
    }

    @discardableResult
    private func seedHealthyImage(_ fixture: Fixture, reference: String) async throws -> SHA256.Digest {
        let data = Data(Self.healthyIndexJSON.utf8)
        let digest = SHA256.hash(data: data)
        try await fixture.contentStore.ingest { ingestDir in
            try data.write(to: ingestDir.appendingPathComponent(digest.encoded))
        }
        _ = try await fixture.store.create(
            description: Containerization.Image.Description(
                reference: reference,
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: digest.digestString,
                    size: Int64(data.count))))
        return digest
    }
}
