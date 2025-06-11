//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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

import AsyncHTTPClient
import ContainerizationError
import ContainerizationExtras
import Crypto
import Foundation

#if os(macOS)
import NIOFileSystem
#endif

extension RegistryClient {
    /// Resolve sends a HEAD request to the registry to find root manifest descriptor.
    /// This descriptor serves as an entry point to retrieve resources from the registry.
    public func resolve(name: String, tag: String) async throws -> Descriptor {
        var components = base

        // Make HEAD request to retrieve the digest header
        components.path = "/v2/\(name)/manifests/\(tag)"

        // The client should include an Accept header indicating which manifest content types it supports.
        let mediaTypes = [
            MediaTypes.dockerManifest,
            MediaTypes.dockerManifestList,
            MediaTypes.imageManifest,
            MediaTypes.index,
            "*/*",
        ]

        let headers = [
            ("Accept", mediaTypes.joined(separator: ", "))
        ]

        return try await request(components: components, method: .HEAD, headers: headers) { response in
            guard response.status == .ok else {
                let url = components.url?.absoluteString ?? "unknown"
                throw Error.invalidStatus(url: url, response.status)
            }

            guard let digest = response.headers.first(name: "Docker-Content-Digest") else {
                throw ContainerizationError(.invalidArgument, message: "Missing required header Docker-Content-Digest")
            }

            guard let type = response.headers.first(name: "Content-Type") else {
                throw ContainerizationError(.invalidArgument, message: "Missing required header Content-Type")
            }

            guard let sizeStr = response.headers.first(name: "Content-Length") else {
                throw ContainerizationError(.invalidArgument, message: "Missing required header Content-Length")
            }

            guard let size = Int64(sizeStr) else {
                throw ContainerizationError(.invalidArgument, message: "Cannot convert \(sizeStr) to Int64")
            }

            return Descriptor(mediaType: type, digest: digest, size: size)
        }
    }

    /// Fetch resource (either manifest or blob) to memory with JSON decoding.
    public func fetch<T: Codable>(name: String, descriptor: Descriptor) async throws -> T {
        var components = base

        let manifestTypes = [
            MediaTypes.dockerManifest,
            MediaTypes.dockerManifestList,
            MediaTypes.imageManifest,
            MediaTypes.index,
        ]

        let isManifest = manifestTypes.contains(where: { $0 == descriptor.mediaType })
        let resource = isManifest ? "manifests" : "blobs"

        components.path = "/v2/\(name)/\(resource)/\(descriptor.digest)"

        let mediaType = descriptor.mediaType
        if mediaType.isEmpty {
            throw ContainerizationError(.invalidArgument, message: "Missing media type for descriptor \(descriptor.digest)")
        }

        let headers = [
            ("Accept", mediaType)
        ]

        return try await requestJSON(components: components, headers: headers)
    }

    /// Fetch resource (either manifest or blob) to memory as raw `Data`.
    public func fetchData(name: String, descriptor: Descriptor) async throws -> Data {
        var components = base

        let manifestTypes = [
            MediaTypes.dockerManifest,
            MediaTypes.dockerManifestList,
            MediaTypes.imageManifest,
            MediaTypes.index,
        ]

        let isManifest = manifestTypes.contains(where: { $0 == descriptor.mediaType })
        let resource = isManifest ? "manifests" : "blobs"

        components.path = "/v2/\(name)/\(resource)/\(descriptor.digest)"

        let mediaType = descriptor.mediaType
        if mediaType.isEmpty {
            throw ContainerizationError(.invalidArgument, message: "Missing media type for descriptor \(descriptor.digest)")
        }

        let headers = [
            ("Accept", mediaType)
        ]

        return try await requestData(components: components, headers: headers)
    }

    /// Fetch a blob from remote registry.
    /// This method is suitable for streaming data.
    public func fetchBlob(
        name: String,
        descriptor: Descriptor,
        closure: (Int64, HTTPClientResponse.Body) async throws -> Void
    ) async throws {
        var components = base
        components.path = "/v2/\(name)/blobs/\(descriptor.digest)"

        let mediaType = descriptor.mediaType
        if mediaType.isEmpty {
            throw ContainerizationError(.invalidArgument, message: "Missing media type for descriptor \(descriptor.digest)")
        }

        let headers = [
            ("Accept", mediaType)
        ]

        try await request(components: components, headers: headers) { response in
            guard response.status == .ok else {
                let url = components.url?.absoluteString ?? "unknown"
                throw Error.invalidStatus(url: url, response.status)
            }

            // How many bytes to expect
            guard let expectedBytes = response.headers.first(name: "Content-Length").flatMap(Int64.init) else {
                throw ContainerizationError(.invalidArgument, message: "Missing required header Content-Length")
            }

            try await closure(expectedBytes, response.body)
        }
    }

    #if os(macOS)
    /// Fetch a blob from remote registry and write the contents into a file in the provided directory.
    public func fetchBlob(name: String, descriptor: Descriptor, into file: URL, progress: ProgressHandler?) async throws -> (Int64, SHA256Digest) {
        var hasher = SHA256()
        var received: Int64 = 0
        let fs = NIOFileSystem.FileSystem.shared
        let handle = try await fs.openFile(forWritingAt: FilePath(file.absolutePath()), options: .newFile(replaceExisting: true))
        var writer = handle.bufferedWriter()
        do {
            try await self.fetchBlob(name: name, descriptor: descriptor) { (size, body) in
                var itr = body.makeAsyncIterator()
                while var buf = try await itr.next() {
                    let readBytes = Int64(buf.readableBytes)
                    received += readBytes
                    let written = try await writer.write(contentsOf: buf)
                    await progress?([
                        ProgressEvent(event: "add-size", value: written)
                    ])
                    guard written == readBytes else {
                        throw ContainerizationError(.internalError, message: "Could not write \(readBytes) bytes to file \(file)")
                    }
                    guard let d = buf.readData(length: buf.readableBytes) else {
                        throw ContainerizationError(.internalError, message: "Failed to convert byte buffer to data to compute checksum")
                    }
                    hasher.update(data: d)
                }
            }
            try await writer.flush()
            try await handle.close()
        } catch {
            try? await handle.close()
            throw error
        }
        let computedDigest = hasher.finalize()
        return (received, computedDigest)
    }
    #else
    /// Fetch a blob from remote registry and write the contents into a file in the provided directory.
    public func fetchBlob(name: String, descriptor: Descriptor, into file: URL, progress: ProgressHandler?) async throws -> (Int64, SHA256Digest) {
        var hasher = SHA256()
        var received: Int64 = 0
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw ContainerizationError(.internalError, message: "Cannot create file at path \(file.path)")
        }
        try await self.fetchBlob(name: name, descriptor: descriptor) { (size, body) in
            let fd = try FileHandle(forWritingTo: file)
            defer {
                try? fd.close()
            }
            var itr = body.makeAsyncIterator()
            while let buf = try await itr.next() {
                let readBytes = Int64(buf.readableBytes)
                received += readBytes
                await progress?([
                    ProgressEvent(event: "add-size", value: readBytes)
                ])
                try buf.withUnsafeReadableBytes { pointer in
                    let unsafeBufferPointer = pointer.bindMemory(to: [UInt8].self)
                    if let addr = unsafeBufferPointer.baseAddress {
                        let d = Data(bytes: addr, count: buf.readableBytes)
                        try fd.write(contentsOf: d)
                        hasher.update(data: d)
                    }
                }
            }
        }
        let computedDigest = hasher.finalize()
        return (received, computedDigest)
    }
    #endif
}
