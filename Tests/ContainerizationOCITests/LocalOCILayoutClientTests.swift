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

import Crypto
import Foundation
import NIOCore
import NIOFoundationCompat
import Testing

@testable import ContainerizationOCI

@Suite
struct LocalOCILayoutClientTests {
    private static let digest = "sha256:" + String(repeating: "c", count: 64)

    @Test func fetchBlobRejectsSymlinkedLayoutEntry() async throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A file outside the root directory.
        let outsideDir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outsideTarget = outsideDir.appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("sensitive host contents".utf8).write(to: outsideTarget)

        let client = try LocalOCILayoutClient(root: root)

        // create a blob entry under blobs/sha256 that is a symlink pointing to
        // a file outside the root directory.
        let blobPath = root.appendingPathComponent("blobs/sha256").appendingPathComponent(try Self.digest.validatedDigestEncoding())
        try FileManager.default.createSymbolicLink(at: blobPath, withDestinationURL: outsideTarget)

        let descriptor = Descriptor(mediaType: "application/octet-stream", digest: Self.digest, size: 1)
        let destination = root.appendingPathComponent("ingest").appendingPathComponent(UUID().uuidString)

        await #expect(throws: (any Error).self) {
            try await client.fetchBlob(name: "test", descriptor: descriptor, into: destination, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func fetchBlobCopiesRegularLayoutEntry() async throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try LocalOCILayoutClient(root: root)

        let blobPath = root.appendingPathComponent("blobs/sha256").appendingPathComponent(try Self.digest.validatedDigestEncoding())
        let data = Data("regular blob contents".utf8)
        try data.write(to: blobPath)

        let descriptor = Descriptor(mediaType: "application/octet-stream", digest: Self.digest, size: Int64(data.count))
        let destination = root.appendingPathComponent("ingest").appendingPathComponent(UUID().uuidString)

        let (size, _) = try await client.fetchBlob(name: "test", descriptor: descriptor, into: destination, progress: nil)
        #expect(size == Int64(data.count))
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test func fetchBlobRejectsPreExistingDestination() async throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try LocalOCILayoutClient(root: root)

        let blobPath = root.appendingPathComponent("blobs/sha256").appendingPathComponent(try Self.digest.validatedDigestEncoding())
        let data = Data("regular blob contents".utf8)
        try data.write(to: blobPath)

        let descriptor = Descriptor(mediaType: "application/octet-stream", digest: Self.digest, size: Int64(data.count))
        let destination = root.appendingPathComponent("ingest").appendingPathComponent(UUID().uuidString)
        try Data("unexpected pre-existing contents".utf8).write(to: destination)

        await #expect(throws: (any Error).self) {
            try await client.fetchBlob(name: "test", descriptor: descriptor, into: destination, progress: nil)
        }
    }

    @Test func fetchDataRejectsSymlinkedLayoutEntry() async throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A file outside the root directory.
        let outsideDir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outsideTarget = outsideDir.appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("outsideTarget content".utf8).write(to: outsideTarget)

        let client = try LocalOCILayoutClient(root: root)

        let blobPath = root.appendingPathComponent("blobs/sha256").appendingPathComponent(try Self.digest.validatedDigestEncoding())
        try FileManager.default.createSymbolicLink(at: blobPath, withDestinationURL: outsideTarget)

        let descriptor = Descriptor(mediaType: "application/octet-stream", digest: Self.digest, size: 1)

        await #expect(throws: (any Error).self) {
            _ = try await client.fetchData(name: "test", descriptor: descriptor)
        }
    }

    @Test func fetchDataCopiesRegularLayoutEntry() async throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try LocalOCILayoutClient(root: root)
        let data = Data("small blob contents".utf8)
        let blobPath = root.appendingPathComponent("blobs/sha256").appendingPathComponent(try Self.digest.validatedDigestEncoding())
        try data.write(to: blobPath)

        let descriptor = Descriptor(mediaType: "application/octet-stream", digest: Self.digest, size: Int64(data.count))
        let fetched = try await client.fetchData(name: "test", descriptor: descriptor)
        #expect(fetched == data)
    }

    @Test func fetchRejectsSymlinkedManifestEntry() async throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A file outside the root directory.
        let outsideDir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outsideTarget = outsideDir.appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("outsideTarget content".utf8).write(to: outsideTarget)

        let client = try LocalOCILayoutClient(root: root)

        let blobPath = root.appendingPathComponent("blobs/sha256").appendingPathComponent(try Self.digest.validatedDigestEncoding())
        try FileManager.default.createSymbolicLink(at: blobPath, withDestinationURL: outsideTarget)

        let descriptor = Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: Self.digest, size: 1)

        await #expect(throws: (any Error).self) {
            let _: [String: String] = try await client.fetch(name: "test", descriptor: descriptor)
        }
    }

    private func byteBufferGenerator(for data: Data) -> () -> AsyncStream<ByteBuffer> {
        {
            AsyncStream { continuation in
                continuation.yield(ByteBuffer(data: data))
                continuation.finish()
            }
        }
    }

    @Test func pushCommitsContentMatchingDigest() async throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try LocalOCILayoutClient(root: root)
        let data = Data("push me".utf8)
        let digest = SHA256.hash(data: data).digestString
        let descriptor = Descriptor(mediaType: "application/octet-stream", digest: digest, size: Int64(data.count))

        try await client.push(
            name: "test", ref: "latest", descriptor: descriptor,
            streamGenerator: byteBufferGenerator(for: data), progress: nil)

        let blobPath = root.appendingPathComponent("blobs/sha256").appendingPathComponent(try digest.validatedDigestEncoding())
        #expect(FileManager.default.fileExists(atPath: blobPath.path))
        #expect(try Data(contentsOf: blobPath) == data)
    }

    @Test func pushRejectsContentWithMismatchedDigest() async throws {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = try LocalOCILayoutClient(root: root)
        let data = Data("push me".utf8)
        // A digest that does not match `data`'s real content.
        let claimedDigest = "sha256:" + String(repeating: "d", count: 64)
        let descriptor = Descriptor(mediaType: "application/octet-stream", digest: claimedDigest, size: Int64(data.count))

        await #expect(throws: (any Error).self) {
            try await client.push(
                name: "test", ref: "latest", descriptor: descriptor,
                streamGenerator: byteBufferGenerator(for: data), progress: nil)
        }

        // Nothing should be committed under the claimed (wrong) digest.
        let blobPath = root.appendingPathComponent("blobs/sha256").appendingPathComponent(try claimedDigest.validatedDigestEncoding())
        #expect(!FileManager.default.fileExists(atPath: blobPath.path))

        // The ingest session's temp directory should be cleaned up.
        let ingestDir = root.appendingPathComponent("ingest")
        let leftover = try FileManager.default.contentsOfDirectory(at: ingestDir, includingPropertiesForKeys: nil)
        #expect(leftover.isEmpty)
    }
}
