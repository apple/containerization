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

import SystemPackage

#if canImport(_NIOFileSystem)
import NIOCore
import _NIOFileSystem
#endif

/// Errors that can occur during TAR reading.
public enum TarReaderError: Error, Sendable {
    /// Unexpected end of archive.
    case unexpectedEndOfArchive

    /// Invalid header (checksum failed or corrupt).
    case invalidHeader

    /// Failed to parse PAX extended data.
    case invalidPaxData

    /// PAX data exceeds maximum allowed size.
    case paxDataTooLarge(Int)

    /// I/O error during reading.
    case ioError(Errno)

    /// Invalid state.
    case invalidState(String)

    /// Entry type not supported.
    case unsupportedEntryType(UInt8)

    /// Path traversal attempt detected.
    case pathTraversal(String)
}

/// A TAR archive reader with PAX support.
///
/// Example usage:
/// ```swift
/// let reader = try TarReader(fileDescriptor: fd)
///
/// let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)
/// defer { buffer.deallocate() }
///
/// while let header = try reader.nextHeader() {
///     print("Entry: \(header.path)")
///
///     if header.entryType.isRegularFile {
///         while reader.contentBytesRemaining > 0 {
///             let bytesRead = try reader.readContent(into: buffer)
///             // Process buffer[0..<bytesRead]
///         }
///     }
/// }
/// ```
public final class TarReader {
    /// The underlying file descriptor.
    private let fileDescriptor: FileDescriptor

    /// Whether we own the file descriptor and should close it.
    private let ownsFileDescriptor: Bool

    /// Internal buffer for header/metadata reads.
    private var internalBuffer: [UInt8]

    /// Reusable buffer for streaming file content.
    private let copyBuffer: UnsafeMutableRawBufferPointer

    /// Current PAX overrides (from extended header).
    private var paxOverrides: [String: String] = [:]

    /// Current entry header.
    private var currentHeader: TarHeader?

    /// Bytes remaining to read for current entry content.
    public private(set) var contentBytesRemaining: Int64 = 0

    /// Bytes remaining to skip for padding.
    private var paddingBytesRemaining: Int = 0

    /// Whether we've reached the end of archive.
    private var endOfArchive = false

    /// Create a TAR reader from a file descriptor.
    /// - Parameters:
    ///   - fileDescriptor: The file descriptor to read from.
    ///   - ownsFileDescriptor: If true, the reader will close the file descriptor when done.
    public init(fileDescriptor: FileDescriptor, ownsFileDescriptor: Bool = false) {
        self.fileDescriptor = fileDescriptor
        self.ownsFileDescriptor = ownsFileDescriptor
        self.internalBuffer = [UInt8](repeating: 0, count: 16384)
        self.copyBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 128 * 1024, alignment: 1)
    }

    /// Create a TAR reader from a file path.
    /// - Parameter path: The path to the TAR file.
    public convenience init(path: FilePath) throws {
        let fd = try FileDescriptor.open(path, .readOnly)
        self.init(fileDescriptor: fd, ownsFileDescriptor: true)
    }

    deinit {
        copyBuffer.deallocate()
        if ownsFileDescriptor {
            try? fileDescriptor.close()
        }
    }

    /// Read the next entry header from the archive.
    /// Returns nil when end of archive is reached.
    public func nextHeader() throws -> TarHeader? {
        if endOfArchive {
            return nil
        }

        // Skip any remaining content/padding from previous entry
        try skipRemainingContent()

        while true {
            try readExactInternal(into: &internalBuffer, count: TarConstants.blockSize)

            if internalBuffer[0..<TarConstants.blockSize].allSatisfy({ $0 == 0 }) {
                endOfArchive = true
                return nil
            }

            guard var header = TarHeader.parse(from: internalBuffer) else {
                throw TarReaderError.invalidHeader
            }

            // Handle PAX extended headers
            if header.entryType == .paxExtended {
                let paxSize = Int(header.size)
                if paxSize > TarConstants.maxPaxSize {
                    throw TarReaderError.paxDataTooLarge(paxSize)
                }
                if paxSize > internalBuffer.count {
                    internalBuffer = [UInt8](repeating: 0, count: paxSize)
                }
                try readExactInternal(into: &internalBuffer, count: paxSize)
                paxOverrides = TarPax.parseRecords(Array(internalBuffer[0..<paxSize]))

                try skipPadding(for: header.size)

                continue
            } else if header.entryType == .paxGlobal {
                let paxSize = Int(header.size)
                if paxSize > TarConstants.maxPaxSize {
                    throw TarReaderError.paxDataTooLarge(paxSize)
                }
                try skipBytes(paxSize)
                try skipPadding(for: header.size)
                continue
            }

            // Apply PAX overrides if any
            if !paxOverrides.isEmpty {
                TarPax.applyOverrides(paxOverrides, to: &header)
                paxOverrides.removeAll()
            }

            currentHeader = header
            contentBytesRemaining = header.size

            // Calculate padding that will need to be skipped
            let remainder = Int(header.size % Int64(TarConstants.blockSize))
            paddingBytesRemaining = remainder == 0 ? 0 : TarConstants.blockSize - remainder

            return header
        }
    }

    /// Read content from the current entry into the provided buffer.
    /// - Parameter buffer: The buffer to read into. Reads up to buffer.count bytes.
    /// - Returns: The number of bytes read. Returns 0 when no content remains.
    public func readContent(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard currentHeader != nil else {
            throw TarReaderError.invalidState("No current entry - call nextHeader() first")
        }

        guard contentBytesRemaining > 0, buffer.count > 0 else {
            return 0
        }

        let toRead = min(Int(contentBytesRemaining), buffer.count)
        var totalRead = 0

        guard let baseAddress = buffer.baseAddress else {
            return 0
        }

        while totalRead < toRead {
            let remaining = UnsafeMutableRawBufferPointer(
                start: baseAddress.advanced(by: totalRead),
                count: toRead - totalRead
            )
            let bytesRead = try fileDescriptor.read(into: remaining)
            if bytesRead == 0 {
                throw TarReaderError.unexpectedEndOfArchive
            }
            totalRead += bytesRead
        }

        contentBytesRemaining -= Int64(totalRead)

        // If we've read all content, skip padding automatically
        if contentBytesRemaining == 0 && paddingBytesRemaining > 0 {
            try skipBytes(paddingBytesRemaining)
            paddingBytesRemaining = 0
        }

        return totalRead
    }

    /// Skip the remaining content of the current entry.
    /// Call this if you don't need the content and want to move to the next entry.
    public func skipRemainingContent() throws {
        while contentBytesRemaining > 0 {
            let toSkip = min(Int(contentBytesRemaining), internalBuffer.count)
            try readExactInternal(into: &internalBuffer, count: toSkip)
            contentBytesRemaining -= Int64(toSkip)
        }

        if paddingBytesRemaining > 0 {
            try skipBytes(paddingBytesRemaining)
            paddingBytesRemaining = 0
        }

        currentHeader = nil
    }

    /// Copy the current entry's content to a destination file descriptor.
    /// - Parameter destination: The file descriptor to write content to.
    /// - Throws: `TarReaderError.invalidState` if no current entry exists.
    public func readFile(to destination: FileDescriptor) throws {
        guard currentHeader != nil else {
            throw TarReaderError.invalidState("No current entry - call nextHeader() first")
        }

        while contentBytesRemaining > 0 {
            let toRead = min(Int(contentBytesRemaining), copyBuffer.count)
            let bytesRead = try readContent(into: UnsafeMutableRawBufferPointer(rebasing: copyBuffer[0..<toRead]))
            if bytesRead == 0 {
                break
            }
            try writeAll(UnsafeRawBufferPointer(rebasing: copyBuffer[0..<bytesRead]), to: destination)
        }
    }

    #if canImport(_NIOFileSystem)
    /// Copy the current entry's content to an async writable file handle.
    /// - Parameter destination: The file handle to write content to.
    /// - Throws: `TarReaderError.invalidState` if no current entry exists.
    public func readFile(to destination: some WritableFileHandleProtocol) async throws {
        guard currentHeader != nil else {
            throw TarReaderError.invalidState("No current entry - call nextHeader() first")
        }

        var offset: Int64 = 0
        while contentBytesRemaining > 0 {
            let toRead = min(Int(contentBytesRemaining), copyBuffer.count)
            let bytesRead = try readContent(into: UnsafeMutableRawBufferPointer(rebasing: copyBuffer[0..<toRead]))
            if bytesRead == 0 {
                break
            }
            let slice = UnsafeRawBufferPointer(rebasing: copyBuffer[0..<bytesRead])
            try await destination.write(contentsOf: Array(slice), toAbsoluteOffset: offset)
            offset += Int64(bytesRead)
        }
    }
    #endif

    /// Write all bytes from the buffer to a file descriptor.
    private func writeAll(_ buffer: UnsafeRawBufferPointer, to fd: FileDescriptor) throws {
        var totalWritten = 0
        while totalWritten < buffer.count {
            let remaining = UnsafeRawBufferPointer(rebasing: buffer[totalWritten...])
            let written = try fd.write(remaining)
            if written == 0 {
                throw TarReaderError.ioError(Errno(rawValue: 0))
            }
            totalWritten += written
        }
    }

    /// Read exactly `count` bytes into the internal buffer array.
    private func readExactInternal(into buffer: inout [UInt8], count: Int) throws {
        var totalRead = 0
        try buffer.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else {
                return
            }
            while totalRead < count {
                let remaining = UnsafeMutableRawBufferPointer(
                    start: baseAddress.advanced(by: totalRead),
                    count: count - totalRead
                )
                let bytesRead = try fileDescriptor.read(into: remaining)
                if bytesRead == 0 {
                    throw TarReaderError.unexpectedEndOfArchive
                }
                totalRead += bytesRead
            }
        }
    }

    /// Skip padding after content.
    private func skipPadding(for size: Int64) throws {
        let remainder = Int(size % Int64(TarConstants.blockSize))
        if remainder > 0 {
            let paddingSize = TarConstants.blockSize - remainder
            try skipBytes(paddingSize)
        }
    }

    /// Skip the specified number of bytes.
    private func skipBytes(_ count: Int) throws {
        var remaining = count
        while remaining > 0 {
            let toSkip = min(remaining, internalBuffer.count)
            try readExactInternal(into: &internalBuffer, count: toSkip)
            remaining -= toSkip
        }
    }
}
