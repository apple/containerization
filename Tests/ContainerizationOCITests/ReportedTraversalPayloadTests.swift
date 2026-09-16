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
import ContainerizationIO
import Crypto
import Foundation
import Testing

@testable import ContainerizationOCI

/// The verbatim payload shapes from the two path-traversal disclosure reports,
/// run through the real public API rather than a re-implementation of it.
///
/// Both reports reached the same sinks through `String.trimmingDigestPrefix`,
/// which returns `../../etc/hosts` for `sha256:../../etc/hosts`.
@Suite
struct ReportedTraversalPayloadTests {
    /// Payloads exactly as the reports wrote them. `victimRelative` is a real
    /// absolute path with its leading separator dropped, which is how both PoCs
    /// aim a fixed count of `../` at an arbitrary target.
    private static func payloads(victimRelative: String) -> [String] {
        [
            // Report 1
            "sha256:../../../../etc/hosts",
            "sha256:" + String(repeating: "../", count: 40) + "etc/hosts",
            // Report 2
            "sha256:" + String(repeating: "../", count: 64) + victimRelative,
            // Report 2, no-colon form: trimmingDigestPrefix returns this unchanged.
            String(repeating: "../", count: 64) + victimRelative,
            // Report 2 also flagged backslash separators.
            "sha256:..\\..\\etc\\hosts",
        ]
    }

    /// Sink 1 in both reports: the read oracle.
    @Test func readSinkIsClosed() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let victim = dir.appendingPathComponent("victim.txt")
        let original = "ORIGINAL victim content"
        try Data(original.utf8).write(to: victim)

        let victimRelative = String(victim.path.drop(while: { $0 == "/" }))
        for payload in Self.payloads(victimRelative: victimRelative) {
            do {
                _ = try await store.get(digest: payload)
                Issue.record("payload was not rejected: \(payload)")
            } catch let error as ContainerizationError {
                // Must be invalidArgument, not notFound: `get` maps notFound to
                // nil, which would hide the escape from every caller.
                #expect(error.code == .invalidArgument, "wrong code for \(payload)")
            }
        }

        #expect(try String(contentsOf: victim, encoding: .utf8) == original)
    }

    /// Sink 2 in both reports, and report 2's headline claim. Note that in the
    /// real `ImageStore+Import.fetch` this sink was never exploitable: the source
    /// and the destination are both derived from the same digest, and
    /// `blobs/sha256` and `ingest/<uuid>` sit at equal depth under one base, so
    /// the two collapse to a single path and `copyItem` fails. Report 2's PoC
    /// substituted an independent source blob. Either way the destination is now
    /// rejected before any copy is attempted.
    @Test func copyDestinationSinkIsClosed() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalContentStore(path: dir)
        let session = try await store.newIngestSession()

        let victim = dir.appendingPathComponent("victim.txt")
        let original = "ORIGINAL victim content"
        try Data(original.utf8).write(to: victim)

        let victimRelative = String(victim.path.drop(while: { $0 == "/" }))
        for payload in Self.payloads(victimRelative: victimRelative) {
            #expect(throws: ContainerizationError.self) {
                try ParsedDigest(parsingPathComponent: payload).path(in: session.ingestDir)
            }
        }

        #expect(try String(contentsOf: victim, encoding: .utf8) == original)
        try await store.cancelIngestSession(session.id)
    }

    /// The write primitive that was genuinely reachable, and which neither report
    /// named: `LocalOCILayoutClient.push`.
    ///
    /// Unlike the import copy above, here the write root is an ingest session in
    /// the *output* layout while the bytes come from the local store — unrelated
    /// roots, so no collapse protects anything. `FileManager.createFile` truncates
    /// an existing file, so pre-fix a traversing digest overwrote an arbitrary
    /// path with attacker-supplied bytes. Reached by `ImageStore.save` after a
    /// poisoned index has been persisted.
    @Test func layoutPushWriteSinkIsClosed() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The victim sits outside the output layout entirely.
        let victim = dir.appendingPathComponent("authorized_keys")
        let original = "ssh-ed25519 ORIGINAL"
        try Data(original.utf8).write(to: victim)

        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let client = try LocalOCILayoutClient(root: out)

        let attackerBytes = Data("## ATTACKER-CONTROLLED PAYLOAD ##".utf8)
        let victimRelative = String(victim.path.drop(while: { $0 == "/" }))

        for payload in Self.payloads(victimRelative: victimRelative) {
            let descriptor = Descriptor(
                mediaType: MediaTypes.imageLayer,
                digest: payload,
                size: Int64(attackerBytes.count))
            let stream = ReadStream(data: attackerBytes)

            await #expect(throws: (any Swift.Error).self) {
                try await client.push(
                    name: "evil/image",
                    ref: "latest",
                    descriptor: descriptor,
                    streamGenerator: {
                        try stream.reset()
                        return stream.stream
                    },
                    progress: nil)
            }

            // Neither truncated nor overwritten.
            #expect(FileManager.default.fileExists(atPath: victim.path))
            #expect(try String(contentsOf: victim, encoding: .utf8) == original)
        }
    }

    /// The `cctl image load` entry point: an attacker-supplied OCI layout whose
    /// `index.json` carries a traversing child digest. Neither report's PoC
    /// exercised this, and it is the one path where the layout directory itself
    /// is attacker controlled.
    @Test func ociLayoutWithTraversingDigestIsRejected() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let layout = dir.appendingPathComponent("layout")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        try Data("{\"imageLayoutVersion\":\"1.0.0\"}".utf8)
            .write(to: layout.appendingPathComponent("oci-layout"))

        let indexJSON = """
            {"schemaVersion":2,"manifests":[
              {"mediaType":"application/vnd.oci.image.manifest.v1+json",
               "digest":"sha256:../../../../etc/hosts","size":10,
               "platform":{"architecture":"arm64","os":"linux"}}
            ]}
            """
        try Data(indexJSON.utf8).write(to: layout.appendingPathComponent("index.json"))

        let client = try LocalOCILayoutClient(root: layout)
        // Rejected while decoding index.json, before any descriptor is used.
        #expect(throws: (any Swift.Error).self) {
            try client.loadIndexFromOCILayout(directory: layout)
        }
    }

    /// A well formed layout still loads, so the check above is rejecting the
    /// digest rather than the layout format.
    @Test func wellFormedOCILayoutStillLoads() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let layout = dir.appendingPathComponent("layout")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        try Data("{\"imageLayoutVersion\":\"1.0.0\"}".utf8)
            .write(to: layout.appendingPathComponent("oci-layout"))

        let digest = SHA256.hash(data: Data("manifest".utf8)).digestString
        let indexJSON = """
            {"schemaVersion":2,"manifests":[
              {"mediaType":"application/vnd.oci.image.manifest.v1+json",
               "digest":"\(digest)","size":10,
               "platform":{"architecture":"arm64","os":"linux"}}
            ]}
            """
        try Data(indexJSON.utf8).write(to: layout.appendingPathComponent("index.json"))

        let client = try LocalOCILayoutClient(root: layout)
        let index = try client.loadIndexFromOCILayout(directory: layout)
        #expect(index.manifests.count == 1)
        #expect(index.manifests[0].digest == digest)
    }
}
