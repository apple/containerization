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

import ContainerizationError
import ContainerizationExtras
import Crypto
import Foundation
import NIOCore
import NIOFoundationCompat

package final class LocalOCILayoutClient: ContentClient {
    let cs: LocalContentStore

    package init(root: URL) throws {
        self.cs = try LocalContentStore(path: root)
    }

    private func _fetch(digest: String) async throws -> Content {
        guard let c: Content = try await self.cs.get(digest: digest) else {
            throw Error.missingContent(digest)
        }
        return c
    }

    package func fetch<T: Codable>(name: String, descriptor: Descriptor) async throws -> T {
        let c = try await self._fetch(digest: descriptor.digest)
        return try c.decode()
    }

    package func fetchBlob(name: String, descriptor: Descriptor, into file: URL, progress: ProgressHandler?) async throws -> (Int64, SHA256Digest) {
        let c = try await self._fetch(digest: descriptor.digest)
        let fileManager = FileManager.default
        let filePath = file.absolutePath()

        let (size, digest) = try ContentWriter.copy(from: c.path, destination: file)

        if let progress, let fileSize = fileManager.fileSize(atPath: filePath) {
            await progress([
                .addSize(fileSize)
            ])
        }
        return (size, digest)
    }

    package func fetchData(name: String, descriptor: Descriptor) async throws -> Data {
        let c = try await self._fetch(digest: descriptor.digest)
        return try c.data()
    }

    package func push<T: Sendable & AsyncSequence>(
        name: String,
        ref: String,
        descriptor: Descriptor,
        streamGenerator: () throws -> T,
        progress: ProgressHandler?
    ) async throws where T.Element == ByteBuffer {
        let input = try streamGenerator()

        let (id, dir) = try await self.cs.newIngestSession()
        do {
            let expected = try ParsedDigest(parsingPathComponent: descriptor.digest)
            let into = try expected.path(in: dir)
            guard FileManager.default.createFile(atPath: into.path, contents: nil) else {
                throw Error.cannotCreateFile
            }
            let fd = try FileHandle(forWritingTo: into)
            defer {
                try? fd.close()
            }
            var wrote = 0
            var hasher = SHA256()

            for try await buffer in input {
                wrote += buffer.readableBytes
                try fd.write(contentsOf: buffer.readableBytesView)
                hasher.update(data: buffer.readableBytesView)
            }
            let actual = ParsedDigest(hasher.finalize())
            guard actual == expected else {
                throw ContainerizationError(
                    .internalError,
                    message: "content digest mismatch")
            }
            try await self.cs.completeIngestSession(id)
        } catch {
            try? await self.cs.cancelIngestSession(id)
            throw error
        }
    }
}

extension LocalOCILayoutClient {
    private static let ociLayoutFileName = "oci-layout"
    private static let ociLayoutVersionString = "imageLayoutVersion"
    private static let ociLayoutIndexFileName = "index.json"

    package func loadIndexFromOCILayout(directory: URL) throws -> ContainerizationOCI.Index {
        let fm = FileManager.default
        let decoder = JSONDecoder()

        let ociLayoutFile = directory.appendingPathComponent(Self.ociLayoutFileName)
        guard fm.fileExists(atPath: ociLayoutFile.absolutePath()) else {
            throw ContainerizationError(.notFound, message: ociLayoutFile.absolutePath())
        }
        var data = try Self.readControlFile(at: ociLayoutFile)
        let ociLayout = try decoder.decode([String: String].self, from: data)
        guard ociLayout[Self.ociLayoutVersionString] != nil else {
            throw ContainerizationError(.empty, message: "missing key \(Self.ociLayoutVersionString) in \(ociLayoutFile.absolutePath())")
        }

        let indexFile = directory.appendingPathComponent(Self.ociLayoutIndexFileName)
        guard fm.fileExists(atPath: indexFile.absolutePath()) else {
            throw ContainerizationError(.notFound, message: indexFile.absolutePath())
        }
        data = try Self.readControlFile(at: indexFile)
        let index = try decoder.decode(ContainerizationOCI.Index.self, from: data)
        return index
    }

    /// Read a layout control file, refusing an oversized one.
    ///
    /// `oci-layout` and `index.json` are read straight out of a caller-supplied
    /// directory before any digest in them has been looked at, so an unbounded
    /// read here is a memory-exhaustion primitive reachable from
    /// `ImageStore.load(from:)`.
    private static func readControlFile(at url: URL) throws -> Data {
        let limit = LocalContent.maxDecodedSize
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw ContainerizationError(
                .invalidArgument,
                message: "\(url.absolutePath()) exceeds the \(limit) byte limit for OCI layout control files")
        }
        return data
    }

    package func createOCILayoutStructure(directory: URL, manifests: [Descriptor]) throws {
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let ingestDir = directory.appendingPathComponent("ingest")
        try? fm.removeItem(at: ingestDir)
        let ociLayoutContent: [String: String] = [
            Self.ociLayoutVersionString: "1.0.0"
        ]

        var data = try encoder.encode(ociLayoutContent)
        var p = directory.appendingPathComponent(Self.ociLayoutFileName).absolutePath()
        guard fm.createFile(atPath: p, contents: data) else {
            throw ContainerizationError(.internalError, message: "failed to create file \(p)")
        }
        let idx = ContainerizationOCI.Index(schemaVersion: 2, manifests: manifests)
        data = try encoder.encode(idx)
        p = directory.appendingPathComponent(Self.ociLayoutIndexFileName).absolutePath()
        guard fm.createFile(atPath: p, contents: data) else {
            throw ContainerizationError(.internalError, message: "failed to create file \(p)")
        }
    }

    package func setImageReferenceAnnotation(descriptor: inout Descriptor, reference: String) {
        var annotations = descriptor.annotations ?? [:]
        annotations[AnnotationKeys.containerizationImageName] = reference
        annotations[AnnotationKeys.containerdImageName] = reference
        annotations[AnnotationKeys.openContainersImageName] = reference
        descriptor.annotations = annotations
    }

    package func getImageReferencefromDescriptor(descriptor: Descriptor) -> String {
        let annotations = descriptor.annotations

        // Annotations here do not conform to the OCI image specification.
        // The interpretation of the annotations "org.opencontainers.image.ref.name" and
        // "io.containerd.image.name" is under debate:
        //  - OCI spec examples suggest it should be the image tag:
        //     https://github.com/opencontainers/image-spec/blob/fbb4662eb53b80bd38f7597406cf1211317768f0/image-layout.md?plain=1#L175
        //  - Buildkitd maintainers argue it should represent the full image name:
        //     https://github.com/moby/buildkit/issues/4615#issuecomment-2521810830
        // Until a consensus is reached, the preference is given to "com.apple.containerization.image.name" and then to
        // using "io.containerd.image.name" as it is the next safest choice
        if let annotations {
            if let name = annotations[AnnotationKeys.containerizationImageName] {
                return name
            }
            if let name = annotations[AnnotationKeys.containerdImageName] {
                return name
            }
            if let name = annotations[AnnotationKeys.openContainersImageName] {
                return name
            }
        }

        // Fallback: Generate digest-based reference for images without annotations
        // This makes sure OCI spec compliance as annotations are optional
        return "untagged@\(descriptor.digest)"
    }

    package enum Error: Swift.Error {
        case missingContent(_ digest: String)
        case unsupportedInput
        case cannotCreateFile
    }
}
