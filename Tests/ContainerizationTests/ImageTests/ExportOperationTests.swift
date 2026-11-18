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
import ContainerizationIO
import ContainerizationOCI
@preconcurrency import Crypto
import Foundation
import NIO
import Testing

@testable import Containerization

@Suite
final class ExportOperationTests {
    @Test(arguments: [MediaTypes.dockerManifestList, MediaTypes.index])
    func testIndexPushMediaTypeMatchesBody(_ sourceMediaType: String) async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cs = try LocalContentStore(path: dir)

        // Opaque child mediaType so ExportOperation's recursion stops here
        // and we don't have to seed config/layer blobs.
        let opaqueType = "application/vnd.test.opaque.v1+json"
        let childData = Data("child-amd64".utf8)
        let childDigest = SHA256.hash(data: childData).digestString
        let childDesc = Descriptor(
            mediaType: opaqueType,
            digest: childDigest,
            size: Int64(childData.count),
            platform: Platform(arch: "amd64", os: "linux"))

        let index = Index(mediaType: sourceMediaType, manifests: [childDesc])
        let indexData = try JSONEncoder().encode(index)
        let indexDigest = SHA256.hash(data: indexData).digestString

        try await cs.ingest { ingestDir in
            for data in [childData, indexData] {
                let path = ingestDir.appendingPathComponent(SHA256.hash(data: data).encoded)
                try data.write(to: path)
            }
        }

        let indexDesc = Descriptor(
            mediaType: sourceMediaType,
            digest: indexDigest,
            size: Int64(indexData.count))

        let capture = CapturingContentClient()
        let op = ImageStore.ExportOperation(
            name: "test/repo", tag: "v1", contentStore: cs, client: capture)
        let pushed = try await op.export(index: indexDesc, platforms: { _ in true })

        #expect(pushed.mediaType == sourceMediaType)

        let indexPush = try #require(
            capture.pushes.first(where: { $0.descriptor.digest == pushed.digest }))
        #expect(indexPush.descriptor.mediaType == sourceMediaType)
        let pushedIndex = try JSONDecoder().decode(Index.self, from: indexPush.body)
        #expect(pushedIndex.mediaType == sourceMediaType)
    }

    /// Export walks the stored index without a platform filter when none is given,
    /// so a traversing digest on an entry a pull never fetched would reach both a
    /// read of an arbitrary host file and a create/truncate of one. It has to be
    /// rejected before anything is pushed.
    @Test func exportRejectsTraversingChildDigest() async throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cs = try LocalContentStore(path: dir)

        let secret = dir.appendingPathComponent("secret.txt")
        try Data("do not read me".utf8).write(to: secret)

        let poisoned = Descriptor(
            mediaType: "application/vnd.test.opaque.v1+json",
            digest: "sha256:../../secret.txt",
            size: 1,
            platform: Platform(arch: "ppc64le", os: "linux"))

        let index = Index(mediaType: MediaTypes.index, manifests: [poisoned])
        let indexData = try JSONEncoder().encode(index)
        let indexDigest = SHA256.hash(data: indexData)

        try await cs.ingest { ingestDir in
            try indexData.write(to: ingestDir.appendingPathComponent(indexDigest.encoded))
        }

        let indexDesc = Descriptor(
            mediaType: MediaTypes.index,
            digest: indexDigest.digestString,
            size: Int64(indexData.count))

        let capture = CapturingContentClient()
        let op = ImageStore.ExportOperation(
            name: "test/repo", tag: "v1", contentStore: cs, client: capture)

        await #expect(throws: (any Swift.Error).self) {
            try await op.export(index: indexDesc, platforms: { _ in true })
        }

        #expect(capture.pushes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: secret.path))
        let contents = try String(contentsOf: secret, encoding: .utf8)
        #expect(contents == "do not read me")
    }

    /// A blob larger than one `ReadStream` buffer reports its bytes while it is being uploaded,
    /// not only once the whole blob has been pushed.
    @Test func pushReportsSizeWhileStreaming() async throws {
        let fixture = try await LargeBlobFixture()
        defer { fixture.cleanUp() }

        let recorder = ProgressRecorder()
        let op = ImageStore.ExportOperation(
            name: "test/repo", tag: "v1", contentStore: fixture.store, client: CapturingContentClient(), progress: recorder.handler)
        try await op.export(index: fixture.index, platforms: { _ in true })

        #expect(recorder.totalSize == recorder.size)
        // The 2.5 MiB blob arrives in three buffers; each is reported as soon as it is consumed.
        let blobReports = recorder.sizeReportsBeforeFirstItem
        #expect(blobReports.count >= 3)
        #expect(blobReports.reduce(0, +) == fixture.blobSize)
    }

    /// A retried upload replaces the bytes reported for the previous attempt instead of adding to
    /// them, so the reported size never exceeds the total.
    @Test func pushRetryDoesNotCountBytesTwice() async throws {
        let fixture = try await LargeBlobFixture()
        defer { fixture.cleanUp() }

        let recorder = ProgressRecorder()
        let client = CapturingContentClient(retryAfterFirstBuffer: true)
        let op = ImageStore.ExportOperation(
            name: "test/repo", tag: "v1", contentStore: fixture.store, client: client, progress: recorder.handler)
        try await op.export(index: fixture.index, platforms: { _ in true })

        #expect(recorder.size == recorder.totalSize)
        #expect(recorder.maxSize <= recorder.totalSize)
        let blobPush = try #require(client.pushes.first(where: { $0.descriptor.digest == fixture.blobDigest }))
        #expect(Int64(blobPush.body.count) == fixture.blobSize)
    }

    /// A failed upload takes back the bytes it had reported.
    @Test func failedPushTakesBackReportedSize() async throws {
        let fixture = try await LargeBlobFixture()
        defer { fixture.cleanUp() }

        let recorder = ProgressRecorder()
        let op = ImageStore.ExportOperation(
            name: "test/repo", tag: "v1", contentStore: fixture.store, client: CapturingContentClient(failAfterFirstBuffer: true),
            progress: recorder.handler)
        await #expect(throws: CapturingContentClient.UploadFailed.self) {
            try await op.export(index: fixture.index, platforms: { _ in true })
        }

        #expect(recorder.maxSize > 0)
        #expect(recorder.size == 0)
    }
}

private final class CapturingContentClient: ContentClient, @unchecked Sendable {
    struct Push: Sendable {
        let descriptor: Descriptor
        let body: Data
    }

    struct UploadFailed: Error {}

    /// Consume the first buffer, then call the stream generator again as a retried request does.
    private let retryAfterFirstBuffer: Bool
    /// Consume the first buffer, then fail the upload.
    private let failAfterFirstBuffer: Bool

    private let lock = NSLock()
    private var _pushes: [Push] = []

    init(retryAfterFirstBuffer: Bool = false, failAfterFirstBuffer: Bool = false) {
        self.retryAfterFirstBuffer = retryAfterFirstBuffer
        self.failAfterFirstBuffer = failAfterFirstBuffer
    }

    var pushes: [Push] {
        lock.withLock { _pushes }
    }

    private struct NotImplemented: Error {}

    func fetch<T: Codable>(name: String, descriptor: Descriptor) async throws -> T {
        throw NotImplemented()
    }

    func fetchBlob(name: String, descriptor: Descriptor, into file: URL, progress: ProgressHandler?) async throws -> (Int64, SHA256Digest) {
        throw NotImplemented()
    }

    func fetchData(name: String, descriptor: Descriptor) async throws -> Data {
        throw NotImplemented()
    }

    func push<T: Sendable & AsyncSequence>(
        name: String,
        ref: String,
        descriptor: Descriptor,
        streamGenerator: () throws -> T,
        progress: ProgressHandler?
    ) async throws where T.Element == ByteBuffer {
        var stream = try streamGenerator()
        if retryAfterFirstBuffer || failAfterFirstBuffer {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
            // Asking for the next buffer reports the first one as consumed.
            _ = try await iterator.next()
            if failAfterFirstBuffer {
                throw UploadFailed()
            }
            stream = try streamGenerator()
        }
        var data = Data()
        for try await buf in stream {
            data.append(contentsOf: buf.readableBytesView)
        }
        lock.withLock {
            _pushes.append(Push(descriptor: descriptor, body: data))
        }
    }
}

/// A content store holding one opaque 2.5 MiB blob and an index that refers to it.
private struct LargeBlobFixture {
    let directory: URL
    let store: LocalContentStore
    let index: Descriptor
    let blobDigest: String
    let blobSize: Int64

    init() async throws {
        directory = FileManager.default.uniqueTemporaryDirectory(create: true)
        store = try LocalContentStore(path: directory)

        // Larger than two `ReadStream` buffers, so the upload takes three of them.
        let blob = Data((0..<(ReadStream.bufferSize * 5 / 2)).map { UInt8(truncatingIfNeeded: $0) })
        blobDigest = SHA256.hash(data: blob).digestString
        blobSize = Int64(blob.count)
        // Opaque mediaType so ExportOperation's recursion stops at the blob.
        let blobDesc = Descriptor(
            mediaType: "application/vnd.test.opaque.v1+json",
            digest: blobDigest,
            size: blobSize,
            platform: Platform(arch: "amd64", os: "linux"))

        let indexData = try JSONEncoder().encode(Index(manifests: [blobDesc]))
        try await store.ingest { ingestDir in
            for data in [blob, indexData] {
                try data.write(to: ingestDir.appendingPathComponent(SHA256.hash(data: data).encoded))
            }
        }
        index = Descriptor(
            mediaType: MediaTypes.index,
            digest: SHA256.hash(data: indexData).digestString,
            size: Int64(indexData.count))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Records the progress events an export reports.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProgressEvent] = []
    private var _maxSize: Int64 = 0

    var handler: ProgressHandler {
        { [self] events in
            lock.withLock {
                self.events.append(contentsOf: events)
                _maxSize = max(_maxSize, sizeLocked)
            }
        }
    }

    private var sizeLocked: Int64 {
        events.reduce(0) { sum, event in
            if case .addSize(let size) = event { return sum + size }
            return sum
        }
    }

    /// The reported size.
    var size: Int64 { lock.withLock { sizeLocked } }

    /// The largest size reported at any point.
    var maxSize: Int64 { lock.withLock { _maxSize } }

    /// The reported total size.
    var totalSize: Int64 {
        lock.withLock {
            events.reduce(0) { sum, event in
                if case .addTotalSize(let size) = event { return sum + size }
                return sum
            }
        }
    }

    /// The sizes reported before the first item completed: the bytes of the first blob, reported
    /// while it was being uploaded.
    var sizeReportsBeforeFirstItem: [Int64] {
        lock.withLock {
            var sizes: [Int64] = []
            for event in events {
                switch event {
                case .addItems: return sizes
                case .addSize(let size): sizes.append(size)
                default: break
                }
            }
            return sizes
        }
    }
}
