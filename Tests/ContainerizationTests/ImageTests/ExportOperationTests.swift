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
import Crypto
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
            for (digest, data) in [(childDigest, childData), (indexDigest, indexData)] {
                let path = ingestDir.appendingPathComponent(digest.trimmingDigestPrefix)
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
}

private final class CapturingContentClient: ContentClient, @unchecked Sendable {
    struct Push: Sendable {
        let descriptor: Descriptor
        let body: Data
    }

    private let lock = NSLock()
    private var _pushes: [Push] = []

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
        let stream = try streamGenerator()
        var data = Data()
        for try await buf in stream {
            data.append(contentsOf: buf.readableBytesView)
        }
        lock.withLock {
            _pushes.append(Push(descriptor: descriptor, body: data))
        }
    }
}
