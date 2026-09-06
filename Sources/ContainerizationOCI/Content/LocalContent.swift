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
import ContainerizationOS
import Crypto
import Foundation

public final class LocalContent: Content {
    /// Maximum size of a document (image manifest, index, or config) that will be
    /// read whole out of the content store by ``data()`` or ``decode()``.
    ///
    /// This matches the 4 MiB response buffer `RegistryClient` already enforces
    /// for the same documents fetched over HTTP, so a document that is readable
    /// from a registry is readable from disk and vice versa. Layer blobs are not
    /// read through these methods; they are streamed or copied.
    public static let maxDecodedSize = Int(4.mib())

    public let path: URL
    private let file: FileHandle

    public init(path: URL) throws {
        // Open with O_NOFOLLOW and verify the target is a regular file.
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ContainerizationError(.notFound, message: "content at path \(path.absolutePath())")
        }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw ContainerizationError(.internalError, message: "failed to stat \(path.absolutePath())")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw ContainerizationError(.internalError, message: "refusing to read non-regular file at \(path.absolutePath())")
        }

        self.file = FileHandle(fileDescriptor: fd)
        self.path = path
    }

    public func digest() throws -> SHA256.Digest {
        let bufferSize = 64 * 1024  // 64 KB
        var hasher = SHA256()

        try self.file.seek(toOffset: 0)
        while case let data = file.readData(ofLength: bufferSize), !data.isEmpty {
            hasher.update(data: data)
        }

        let digest = hasher.finalize()

        try self.file.seek(toOffset: 0)
        return digest
    }

    public func data(offset: UInt64 = 0, length size: Int = 0) throws -> Data? {
        try file.seek(toOffset: offset)
        if size == 0 {
            return try file.readToEnd()
        }
        return try file.read(upToCount: size)
    }

    public func data() throws -> Data {
        try self.boundedContents()
    }

    /// Read the entire file through the already-open descriptor, refusing
    /// anything larger than ``maxDecodedSize``.
    ///
    /// Reading through the open descriptor rather than re-opening the path
    /// deliberately keeps the limit check and the read on the same inode.
    /// ``size()`` uses `attributesOfItem`, which does not traverse symlinks,
    /// while `Data(contentsOf:)` does — so checking the size of a path and then
    /// reading it could be defeated by a symlink at the blob name. Reading one
    /// byte past the limit and comparing is also cheaper than a stat plus a
    /// second open.
    private func boundedContents() throws -> Data {
        let limit = Self.maxDecodedSize
        try self.file.seek(toOffset: 0)
        let data = try self.file.read(upToCount: limit + 1) ?? Data()
        try self.file.seek(toOffset: 0)
        guard data.count <= limit else {
            throw ContainerizationError(
                .invalidArgument,
                message: "content at \(self.path.absolutePath()) exceeds the \(limit) byte limit for documents read from the content store")
        }
        return data
    }

    public func size() throws -> UInt64 {
        var st = stat()
        guard fstat(self.file.fileDescriptor, &st) == 0 else {
            throw ContainerizationError(.internalError, message: "could not determine file size for \(path.absolutePath())")
        }
        return UInt64(st.st_size)
    }

    public func decode<T>() throws -> T where T: Decodable {
        try JSONDecoder().decode(T.self, from: self.boundedContents())
    }

    deinit {
        try? self.file.close()
    }
}
