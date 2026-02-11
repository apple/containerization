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
import Crypto
import Foundation
import NIOCore

/// Provides a context to write data into a directory.
public class ContentWriter {
    private let base: URL
    private let encoder = JSONEncoder()

    /// Create a new ContentWriter.
    /// - Parameters:
    ///   - base: The URL to write content to. If this is not a directory a
    ///           ContainerizationError will be thrown with a code of .internalError.
    public init(for base: URL) throws {
        self.encoder.outputFormatting = [JSONEncoder.OutputFormatting.sortedKeys]

        self.base = base
        var isDirectory = ObjCBool(true)
        let exists = FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory)

        guard exists && isDirectory.boolValue else {
            throw ContainerizationError(.internalError, message: "cannot create ContentWriter for path \(base.absolutePath()), not a directory")
        }
    }

    /// Writes the data blob to the base URL provided in the constructor.
    /// - Parameters:
    ///   - data: The data blob to write to a file under the base path.
    @discardableResult
    public func write(_ data: Data) throws -> (size: Int64, digest: SHA256.Digest) {
        let digest = SHA256.hash(data: data)
        let destination = base.appendingPathComponent(digest.encoded)
        try data.write(to: destination)
        return (Int64(data.count), digest)
    }

    /// Reads the data present in the passed in URL and writes it to the base path.
    /// - Parameters:
    ///   - url: The URL to read the data from.
    @discardableResult
    public func create(from url: URL) throws -> (size: Int64, digest: SHA256.Digest) {
        let data = try Data(contentsOf: url)
        return try self.write(data)
    }

    /// Encodes the passed in type as a JSON blob and writes it to the base path.
    /// - Parameters:
    ///   - content: The type to convert to JSON.
    @discardableResult
    public func create<T: Encodable>(from content: T) throws -> (size: Int64, digest: SHA256.Digest) {
        let data = try self.encoder.encode(content)
        return try self.write(data)
    }
}
