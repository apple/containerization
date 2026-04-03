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
        let sourceFD = Foundation.open(url.path, O_RDONLY)
        guard sourceFD >= 0 else {
            let errCode = POSIXErrorCode(rawValue: errno) ?? .EINVAL
            let err = POSIXError(errCode)
            throw ContainerizationError(.internalError, message: "failed to open \(url.path) for reading", cause: err)
        }
        defer { close(sourceFD) }

        let tempURL = base.appendingPathComponent(UUID().uuidString)
        let destFD = Foundation.open(tempURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard destFD >= 0 else {
            let errCode = POSIXErrorCode(rawValue: errno) ?? .EINVAL
            let err = POSIXError(errCode)
            throw ContainerizationError(.internalError, message: "failed to create temporary file at \(tempURL.absolutePath())", cause: err)
        }

        let chunkSize = 1024 * 1024  // 1 MiB
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer { buf.deallocate() }
        guard let baseAddress = buf.baseAddress else {
            close(destFD)
            try? FileManager.default.removeItem(at: tempURL)
            throw ContainerizationError(.internalError, message: "failed to allocate read buffer of size \(chunkSize)")
        }

        var hasher = SHA256()
        var totalSize: Int64 = 0
        while true {
            let n = read(sourceFD, baseAddress, chunkSize)
            if n == 0 { break }
            if n < 0 {
                close(destFD)
                let errCode = POSIXErrorCode(rawValue: errno) ?? .EINVAL
                let err = POSIXError(errCode)
                try? FileManager.default.removeItem(at: tempURL)
                throw ContainerizationError(.internalError, message: "failed to read from \(url.path)", cause: err)
            }
            hasher.update(data: UnsafeRawBufferPointer(start: baseAddress, count: n))
            var written = 0
            while written < n {
                let w = Foundation.write(destFD, baseAddress.advanced(by: written), n - written)
                if w < 0 {
                    close(destFD)
                    let errCode = POSIXErrorCode(rawValue: errno) ?? .EINVAL
                    let err = POSIXError(errCode)
                    try? FileManager.default.removeItem(at: tempURL)
                    throw ContainerizationError(.internalError, message: "failed to write to \(tempURL.absolutePath())", cause: err)
                }
                written += w
            }
            totalSize += Int64(n)
        }
        close(destFD)

        let digest = hasher.finalize()
        let destination = base.appendingPathComponent(digest.encoded)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch let error as NSError {
            guard error.code == NSFileWriteFileExistsError else {
                throw error
            }
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return (totalSize, digest)
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
