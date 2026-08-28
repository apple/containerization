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
@preconcurrency import Crypto
import Foundation
import Testing

@testable import ContainerizationOCI

@Suite
struct DigestValidationTests {
    private static let validHex = String(repeating: "a", count: 64)
    private static let valid = "sha256:\(validHex)"

    @Test(arguments: [
        "sha256:\(String(repeating: "a", count: 64))",
        "sha256:\(String(repeating: "0", count: 64))",
        "sha256:\(String(repeating: "f", count: 64))",
        String(repeating: "a", count: 64),
    ])
    func acceptsWellFormedDigests(_ digest: String) throws {
        let parsed = try ParsedDigest(parsingPathComponent: digest)
        #expect(parsed.encoded.count == 64)
        #expect(ParsedDigest.isValid(digest))
    }

    @Test(arguments: [
        "",
        "sha256:",
        "sha256:../../../../etc/hosts",
        "../../etc/hosts",
        "sha256:/etc/hosts",
        "sha256:..",
        // Depth one traversal: still inside the store, but it renames a blob and
        // escapes an ingest session directory.
        "sha256:../sha256/\(String(repeating: "a", count: 64))",
        // Uppercase would map one digest to two blob names on a case insensitive
        // filesystem.
        "sha256:\(String(repeating: "A", count: 64))",
        "sha256:\(String(repeating: "a", count: 63))",
        "sha256:\(String(repeating: "a", count: 65))",
        "sha512:\(String(repeating: "a", count: 128))",
        // trimmingDigestPrefix passes multi-colon strings through untouched.
        "sha256:\(String(repeating: "a", count: 64)):\(String(repeating: "a", count: 64))",
        "sha256:\(String(repeating: "a", count: 64))\n",
        "sha256:\(String(repeating: "g", count: 64))",
        // 64 graphemes but 66 bytes: a combining mark composes with a base letter
        // into a Character that compares as inside "a"..."f".
        "sha256:\(String(repeating: "a", count: 63))b\u{0308}",
        "sha256:\(String(repeating: "a", count: 63))\u{0301}",
    ])
    func rejectsMalformedDigests(_ digest: String) throws {
        #expect(!ParsedDigest.isValid(digest))
        #expect(throws: ContainerizationError.self) {
            try ParsedDigest(parsingPathComponent: digest)
        }
    }

    @Test func requiresAlgorithmPrefixWhenParsingStrictly() throws {
        #expect(throws: ContainerizationError.self) {
            try ParsedDigest(parsing: Self.validHex)
        }
        #expect(try ParsedDigest(parsing: Self.valid).encoded == Self.validHex)
    }

    @Test func roundTripsCanonicalForm() throws {
        #expect(try ParsedDigest(parsing: Self.valid).description == Self.valid)
        #expect(try ParsedDigest(parsingPathComponent: Self.validHex).description == Self.valid)
    }

    @Test func bridgesFromComputedHash() throws {
        let computed = SHA256.hash(data: Data("hello".utf8))
        #expect(ParsedDigest(computed).description == computed.digestString)
    }

    @Test func pathStaysWithinRoot() throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = try ParsedDigest(parsing: Self.valid).path(in: root)
        #expect(path.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath())
        #expect(path.lastPathComponent == Self.validHex)
    }

    /// The root and the child must not be symlink-resolved independently.
    /// `resolvingSymlinksInPath()` treats existing and missing paths differently,
    /// so a store under a symlinked root would reject every cache miss while
    /// accepting every hit.
    @Test func pathResolvesConsistentlyUnderSymlinkedRoot() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try await Self.expectHitsAndMissesAgree(storeRoot: link)
    }

    /// The `/private` spelling of a Darwin temporary directory is the other way
    /// the two sides can disagree: `resolvingSymlinksInPath()` strips a leading
    /// `/private` from an existing path but leaves it on a missing one. Darwin
    /// only — on Linux there is no such alias, and prefixing `/private` onto
    /// `/tmp` would have the store create a real `/private` at the filesystem
    /// root.
    #if os(macOS)
    @Test func pathResolvesConsistentlyUnderPrivateSpelledRoot() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeRoot = dir.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let aliased = URL(fileURLWithPath: "/private" + storeRoot.path)
        // Only meaningful if the alias actually names the same directory.
        try #require(FileManager.default.fileExists(atPath: aliased.path))

        try await Self.expectHitsAndMissesAgree(storeRoot: aliased)
    }
    #endif

    private static func expectHitsAndMissesAgree(storeRoot: URL) async throws {
        let store = try LocalContentStore(path: storeRoot)
        let payload = Data("blob".utf8)
        let present = SHA256.hash(data: payload)

        // A miss must be nil, not a containment rejection.
        let miss = try await store.get(digest: Self.valid)
        #expect(miss == nil)

        try await store.ingest { ingestDir in
            try payload.write(to: ingestDir.appendingPathComponent(present.encoded))
        }
        let hit = try await store.get(digest: present.digestString)
        #expect(hit != nil)

        // Traversal is still rejected under either spelling.
        await #expect(throws: ContainerizationError.self) {
            try await store.get(digest: "sha256:../../escape.txt")
        }
    }

    // MARK: - Content store boundary

    @Test func getCannotEscapeBlobRoot() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let secret = dir.appendingPathComponent("secret.txt")
        try Data("do not read me".utf8).write(to: secret)

        // blobs live at <dir>/blobs/sha256, so two levels up is the sentinel.
        for digest in ["sha256:../../secret.txt", "../../secret.txt", "sha256:" + String(repeating: "../", count: 40) + "etc/hosts"] {
            await #expect(throws: ContainerizationError.self) {
                try await store.get(digest: digest)
            }
        }

        // The failure must be an invalid argument, not a miss. `get` maps
        // `notFound` to nil, which would hide the escape entirely.
        do {
            _ = try await store.get(digest: "sha256:../../secret.txt")
            Issue.record("expected a traversing digest to be rejected")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
        }

        #expect(FileManager.default.fileExists(atPath: secret.path))
    }

    @Test func getRejectsEmptyDigestRatherThanReturningBlobDirectory() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        await #expect(throws: ContainerizationError.self) {
            try await store.get(digest: "")
        }
    }

    @Test func getReturnsNilForWellFormedMiss() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let content = try await store.get(digest: Self.valid)
        #expect(content == nil)
    }

    @Test func deleteCannotEscapeBlobRoot() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let victim = dir.appendingPathComponent("victim.txt")
        try Data("keep me".utf8).write(to: victim)

        await #expect(throws: ContainerizationError.self) {
            try await store.delete(digests: ["../../victim.txt"])
        }
        await #expect(throws: ContainerizationError.self) {
            try await store.delete(digests: [""])
        }

        #expect(FileManager.default.fileExists(atPath: victim.path))
        // The blob directory itself must survive an empty digest.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("blobs/sha256").path))
    }

    @Test func deleteKeepingStillReclaimsNonDigestStrays() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        // An interrupted ingest can leave a UUID named file behind, which
        // `completeIngestSession` then moves into the blob directory. Garbage
        // collection still has to be able to reclaim it.
        let stray = "not-a-digest-\(UUID().uuidString)"
        try await store.ingest { ingestDir in
            try Data("stray".utf8).write(to: ingestDir.appendingPathComponent(stray))
        }

        let strayPath = dir.appendingPathComponent("blobs/sha256").appendingPathComponent(stray)
        #expect(FileManager.default.fileExists(atPath: strayPath.path))

        let (deleted, freed) = try await store.delete(keeping: [])
        #expect(deleted.contains(stray))
        #expect(freed > 0)
        #expect(!FileManager.default.fileExists(atPath: strayPath.path))
    }

    @Test func deleteKeepingAcceptsPrefixedDigests() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let payload = Data("keep this blob".utf8)
        let digest = SHA256.hash(data: payload).digestString

        try await store.ingest { ingestDir in
            try payload.write(to: ingestDir.appendingPathComponent(SHA256.hash(data: payload).encoded))
        }

        // Passing the canonical `sha256:<hex>` spelling must not be read as
        // "unreferenced" — that would delete a live blob.
        let (deleted, _) = try await store.delete(keeping: [digest])
        #expect(deleted.isEmpty)
        let kept = try await store.get(digest: digest)
        #expect(kept != nil)
    }

    /// The ingest-directory joins in `ImageStore+Import` are the copy-destination
    /// sink both reports name. Pin that a traversing digest cannot produce a
    /// destination outside the ingest directory, independent of what the source
    /// resolves to.
    @Test func ingestDestinationCannotEscapeIngestDirectory() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let session = try await store.newIngestSession()
        defer { Task { try? await store.cancelIngestSession(session.id) } }

        let victim = dir.appendingPathComponent("victim.txt")
        try Data("ORIGINAL victim content".utf8).write(to: victim)

        // The payload shape used by both reports: many "../" then a real path.
        let payload = "sha256:" + String(repeating: "../", count: 64) + String(victim.path.drop(while: { $0 == "/" }))
        #expect(throws: ContainerizationError.self) {
            try ParsedDigest(parsingPathComponent: payload).path(in: session.ingestDir)
        }

        let contents = try String(contentsOf: victim, encoding: .utf8)
        #expect(contents == "ORIGINAL victim content")
    }

    @Test func decodeRejectsOversizedDocuments() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let oversized = Data(repeating: 0x7B, count: LocalContent.maxDecodedSize + 1)
        try await store.ingest { ingestDir in
            try oversized.write(to: ingestDir.appendingPathComponent(Self.validHex))
        }

        let fetched = try await store.get(digest: Self.valid)
        let content = try #require(fetched)
        #expect(throws: ContainerizationError.self) {
            let _: Index = try content.decode()
        }
    }

    /// `data()` is reached with a caller-declared size that need not match what is
    /// on disk: `ImageStore+Import.fetch` picks the small-blob path from
    /// `descriptor.size`, so a layout declaring `size: 1` on a huge blob would
    /// otherwise read the whole thing into memory before any digest check.
    @Test func dataRejectsOversizedContent() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let oversized = Data(repeating: 0x41, count: LocalContent.maxDecodedSize + 1)
        try await store.ingest { ingestDir in
            try oversized.write(to: ingestDir.appendingPathComponent(Self.validHex))
        }

        let content = try #require(try await store.get(digest: Self.valid))
        #expect(throws: ContainerizationError.self) {
            _ = try content.data()
        }

        // A document at the limit still reads.
        let atLimit = Data(repeating: 0x42, count: LocalContent.maxDecodedSize)
        let atLimitDigest = SHA256.hash(data: atLimit)
        try await store.ingest { ingestDir in
            try atLimit.write(to: ingestDir.appendingPathComponent(atLimitDigest.encoded))
        }
        let ok = try #require(try await store.get(digest: atLimitDigest.digestString))
        #expect(try ok.data().count == LocalContent.maxDecodedSize)
    }
}
