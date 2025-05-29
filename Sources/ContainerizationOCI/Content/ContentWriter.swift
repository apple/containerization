//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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

    private var done: Bool = false

    public init(for base: URL) throws {
        self.base = base
        var isDirectory = ObjCBool(true)
        let exists = FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory)

        guard exists && isDirectory.boolValue else {
            throw ContainerizationError(.internalError, message: "Cannot create ContentWriter for path \(base.absolutePath()). Not a directory")
        }
    }

    @discardableResult
    public func write(_ data: Data) throws -> (size: Int64, digest: SHA256.Digest) {
        let digest = SHA256.hash(data: data)
        let destination = base.appendingPathComponent(digest.encoded)
        try data.write(to: destination)
        return (Int64(data.count), digest)
    }

    @discardableResult
    public func create(from u: URL) throws -> (size: Int64, digest: SHA256.Digest) {
        let data = try Data(contentsOf: u)
        return try self.write(data)
    }

    @discardableResult
    public func create<T: Encodable>(from content: T) throws -> (size: Int64, digest: SHA256.Digest) {
        let data = try self.encoder.encode(content)
        return try self.write(data)
    }
}
