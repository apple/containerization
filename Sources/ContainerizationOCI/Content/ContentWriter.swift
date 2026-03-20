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

import Compression
import ContainerizationError
import Crypto
import Foundation
import NIOCore
import zlib

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

    /// Computes the SHA256 digest of the uncompressed content of a gzip file.
    ///
    /// Per the OCI Image Specification, a DiffID is the SHA256 digest of the
    /// uncompressed layer content. This method decompresses the gzip data and
    /// hashes the result using a streaming approach for memory efficiency.
    ///
    /// - Parameter url: The URL of the gzip-compressed file.
    /// - Returns: The SHA256 digest of the uncompressed content.
    public static func diffID(of url: URL) throws -> SHA256.Digest {
        let compressedData = try Data(contentsOf: url)
        let decompressed = try Self.decompressGzip(compressedData)
        return SHA256.hash(data: decompressed)
    }

    /// Decompresses gzip data by stripping the gzip header and feeding the raw
    /// deflate stream to Apple's Compression framework.
    private static func decompressGzip(_ data: Data) throws -> Data {
        let headerSize = try Self.gzipHeaderSize(data)

        var output = Data()
        let bufferSize = 65_536
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        try data.withUnsafeBytes { rawBuffer in
            guard let sourcePointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw ContentWriterError.decompressionFailed
            }

            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }

            var status = compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw ContentWriterError.decompressionFailed
            }
            defer { compression_stream_destroy(stream) }

            stream.pointee.src_ptr = sourcePointer.advanced(by: headerSize)
            stream.pointee.src_size = data.count - headerSize
            stream.pointee.dst_ptr = destinationBuffer
            stream.pointee.dst_size = bufferSize

            repeat {
                status = compression_stream_process(stream, 0)

                switch status {
                case COMPRESSION_STATUS_OK:
                    let produced = bufferSize - stream.pointee.dst_size
                    output.append(destinationBuffer, count: produced)
                    stream.pointee.dst_ptr = destinationBuffer
                    stream.pointee.dst_size = bufferSize

                case COMPRESSION_STATUS_END:
                    let produced = bufferSize - stream.pointee.dst_size
                    if produced > 0 {
                        output.append(destinationBuffer, count: produced)
                    }

                default:
                    throw ContentWriterError.decompressionFailed
                }
            } while status == COMPRESSION_STATUS_OK
        }

        // Validate the gzip trailer: last 8 bytes are CRC32 + ISIZE (both little-endian).
        guard data.count >= 8 else {
            throw ContentWriterError.gzipTrailerMismatch
        }
        let trailerStart = data.startIndex + data.count - 8
        let expectedCRC = UInt32(data[trailerStart])
            | (UInt32(data[trailerStart + 1]) << 8)
            | (UInt32(data[trailerStart + 2]) << 16)
            | (UInt32(data[trailerStart + 3]) << 24)
        let expectedSize = UInt32(data[trailerStart + 4])
            | (UInt32(data[trailerStart + 5]) << 8)
            | (UInt32(data[trailerStart + 6]) << 16)
            | (UInt32(data[trailerStart + 7]) << 24)

        let actualCRC = output.withUnsafeBytes { buffer -> UInt32 in
            let ptr = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
            return UInt32(crc32(0, ptr, uInt(buffer.count)))
        }
        let actualSize = UInt32(truncatingIfNeeded: output.count)

        guard expectedCRC == actualCRC, expectedSize == actualSize else {
            throw ContentWriterError.gzipTrailerMismatch
        }

        return output
    }

    /// Parses the gzip header to determine where the raw deflate stream begins.
    private static func gzipHeaderSize(_ data: Data) throws -> Int {
        guard data.count >= 10,
              data[data.startIndex] == 0x1f,
              data[data.startIndex + 1] == 0x8b
        else {
            throw ContentWriterError.invalidGzip
        }

        let start = data.startIndex
        let flags = data[start + 3]
        var offset = 10

        // FEXTRA
        if flags & 0x04 != 0 {
            guard data.count >= offset + 2 else { throw ContentWriterError.invalidGzip }
            let extraLen = Int(data[start + offset]) | (Int(data[start + offset + 1]) << 8)
            offset += 2 + extraLen
        }
        // FNAME
        if flags & 0x08 != 0 {
            while offset < data.count && data[start + offset] != 0 { offset += 1 }
            offset += 1
        }
        // FCOMMENT
        if flags & 0x10 != 0 {
            while offset < data.count && data[start + offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC
        if flags & 0x02 != 0 { offset += 2 }

        guard offset < data.count else { throw ContentWriterError.invalidGzip }
        return offset
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

enum ContentWriterError: Error {
    case invalidGzip
    case decompressionFailed
    case gzipTrailerMismatch
}
