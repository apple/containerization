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

    /// Computes the SHA256 digest of the uncompressed content of a gzip file.
    ///
    /// Per the OCI Image Specification, a DiffID is the SHA256 digest of the
    /// uncompressed layer content. This method streams the compressed file in
    /// chunks, decompresses through Apple's Compression framework, and feeds
    /// each decompressed chunk into an incremental SHA256 hasher. Neither the
    /// full compressed nor the full decompressed data is held in memory.
    ///
    /// - Parameter url: The URL of the gzip-compressed file.
    /// - Returns: The SHA256 digest of the uncompressed content.
    public static func diffID(of url: URL) throws -> SHA256.Digest {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }

        let headerReadSize = 512
        guard let headerData = Self.readExactly(fileHandle: fileHandle, count: headerReadSize),
            !headerData.isEmpty
        else {
            throw ContainerizationError(.internalError, message: "invalid gzip file")
        }
        let headerSize = try Self.gzipHeaderSize(headerData)

        fileHandle.seekToEndOfFile()
        let fileSize = fileHandle.offsetInFile
        guard fileSize >= 8 else {
            throw ContainerizationError(.internalError, message: "gzip trailer mismatch")
        }
        fileHandle.seek(toFileOffset: fileSize - 8)
        guard let trailerData = Self.readExactly(fileHandle: fileHandle, count: 8),
            trailerData.count == 8
        else {
            throw ContainerizationError(.internalError, message: "gzip trailer mismatch")
        }
        let expectedCRC =
            UInt32(trailerData[trailerData.startIndex])
            | (UInt32(trailerData[trailerData.startIndex + 1]) << 8)
            | (UInt32(trailerData[trailerData.startIndex + 2]) << 16)
            | (UInt32(trailerData[trailerData.startIndex + 3]) << 24)
        let expectedSize =
            UInt32(trailerData[trailerData.startIndex + 4])
            | (UInt32(trailerData[trailerData.startIndex + 5]) << 8)
            | (UInt32(trailerData[trailerData.startIndex + 6]) << 16)
            | (UInt32(trailerData[trailerData.startIndex + 7]) << 24)

        fileHandle.seek(toFileOffset: UInt64(headerSize))
        var compressedBytesRemaining = Int(fileSize) - headerSize - 8
        guard compressedBytesRemaining >= 0 else {
            throw ContainerizationError(.internalError, message: "invalid gzip file")
        }

        let chunkSize = 65_536
        let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer {
            sourceBuffer.deallocate()
            destinationBuffer.deallocate()
        }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }

        var status = compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw ContainerizationError(.internalError, message: "gzip decompression failed")
        }
        defer { compression_stream_destroy(stream) }

        stream.pointee.src_ptr = UnsafePointer(sourceBuffer)
        stream.pointee.src_size = 0
        stream.pointee.dst_ptr = destinationBuffer
        stream.pointee.dst_size = chunkSize

        var hasher = SHA256()
        var runningCRC: uLong = crc32(0, nil, 0)
        var totalDecompressedSize: UInt64 = 0
        var inputExhausted = false

        while status != COMPRESSION_STATUS_END {
            if stream.pointee.src_size == 0 && !inputExhausted {
                let toRead = min(chunkSize, compressedBytesRemaining)
                if toRead > 0,
                    let chunk = fileHandle.readData(ofLength: toRead) as Data?,
                    !chunk.isEmpty
                {
                    compressedBytesRemaining -= chunk.count
                    chunk.copyBytes(to: sourceBuffer, count: chunk.count)
                    stream.pointee.src_ptr = UnsafePointer(sourceBuffer)
                    stream.pointee.src_size = chunk.count
                } else {
                    inputExhausted = true
                }
            }

            stream.pointee.dst_ptr = destinationBuffer
            stream.pointee.dst_size = chunkSize

            let flags: Int32 = inputExhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            status = compression_stream_process(stream, flags)

            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 {
                    let buf = UnsafeBufferPointer(start: destinationBuffer, count: produced)
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(buf))
                    runningCRC = crc32(runningCRC, destinationBuffer, uInt(produced))
                    totalDecompressedSize += UInt64(produced)
                }
            default:
                throw ContainerizationError(.internalError, message: "gzip decompression failed")
            }
        }

        let actualCRC = UInt32(truncatingIfNeeded: runningCRC)
        let actualSize = UInt32(truncatingIfNeeded: totalDecompressedSize)

        guard expectedCRC == actualCRC, expectedSize == actualSize else {
            throw ContainerizationError(.internalError, message: "gzip trailer mismatch")
        }

        return hasher.finalize()
    }

    private static func readExactly(fileHandle: FileHandle, count: Int) -> Data? {
        let data = fileHandle.readData(ofLength: count)
        return data.isEmpty ? nil : data
    }

    private static func gzipHeaderSize(_ data: Data) throws -> Int {
        guard data.count >= 10,
            data[data.startIndex] == 0x1f,
            data[data.startIndex + 1] == 0x8b,
            data[data.startIndex + 2] == 0x08
        else {
            throw ContainerizationError(.internalError, message: "invalid gzip file")
        }

        let start = data.startIndex
        let flags = data[start + 3]
        var offset = 10

        if flags & 0x04 != 0 {
            guard data.count >= offset + 2 else {
                throw ContainerizationError(.internalError, message: "invalid gzip file")
            }
            let extraLen = Int(data[start + offset]) | (Int(data[start + offset + 1]) << 8)
            offset += 2 + extraLen
        }
        if flags & 0x08 != 0 {
            while offset < data.count && data[start + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < data.count && data[start + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }

        guard offset < data.count else {
            throw ContainerizationError(.internalError, message: "invalid gzip file")
        }
        return offset
    }
}
