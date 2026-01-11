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

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Errors that can occur during TAR writing.
public enum TarWriterError: Error, Sendable {
    /// The path is too long and cannot be represented.
    case pathTooLong(String)

    /// Failed to serialize header.
    case headerSerializationFailed

    /// File size mismatch - wrote different amount than declared.
    case sizeMismatch(expected: Int64, actual: Int64)

    /// I/O error during writing.
    case ioError(Int32)

    /// Write returned zero bytes unexpectedly.
    case writeZeroBytes

    /// Invalid entry state.
    case invalidState(String)
}

/// A TAR archive writer with PAX support.
///
/// Example usage:
/// ```swift
/// let writer = try TarWriter(fileDescriptor: fd)
///
/// // Write a directory
/// try writer.writeDirectory(path: "mydir", mode: 0o755)
///
/// // Write a file with content from a buffer
/// try writer.beginFile(path: "mydir/hello.txt", size: 13)
/// try buffer.withUnsafeBytes { ptr in
///     try writer.writeContent(ptr)
/// }
/// try writer.finalizeEntry()
///
/// // Write a symlink
/// try writer.writeSymlink(path: "mydir/link", target: "hello.txt")
///
/// // Finalize the archive
/// try writer.finalize()
/// ```
public final class TarWriter {
    private let fileDescriptor: FileDescriptor
    private let ownsFileDescriptor: Bool

    /// Reusable buffer for streaming file content.
    private let copyBuffer: UnsafeMutableRawBufferPointer

    /// Track bytes written for current entry (for size validation).
    private var currentEntryBytesWritten: Int64 = 0
    private var currentEntryExpectedSize: Int64 = 0
    private var writingEntryContent = false

    private var finalized = false

    /// Create a TAR writer from a file descriptor.
    /// - Parameters:
    ///   - fileDescriptor: The file descriptor to write to.
    ///   - ownsFileDescriptor: If true, the writer will close the file descriptor when done.
    public init(fileDescriptor: FileDescriptor, ownsFileDescriptor: Bool = false) {
        self.fileDescriptor = fileDescriptor
        self.ownsFileDescriptor = ownsFileDescriptor
        self.copyBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 128 * 1024, alignment: 1)
    }

    /// Create a TAR writer from a file path.
    /// - Parameter path: The path to the TAR file to create.
    public convenience init(path: FilePath) throws {
        let fd = try FileDescriptor.open(
            path,
            .writeOnly,
            options: [.create, .truncate],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        )
        self.init(fileDescriptor: fd, ownsFileDescriptor: true)
    }

    deinit {
        copyBuffer.deallocate()
        if ownsFileDescriptor {
            try? fileDescriptor.close()
        }
    }

    /// Write a directory entry.
    public func writeDirectory(
        path: String,
        mode: UInt32 = 0o755,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        mtime: Int64? = nil,
        userName: String = "root",
        groupName: String = "root"
    ) throws {
        try ensureNotFinalized()
        try ensureNotWritingContent()

        // Ensure path ends with /
        var dirPath = path
        if !dirPath.hasSuffix("/") {
            dirPath += "/"
        }

        let header = TarHeader(
            path: dirPath,
            mode: mode,
            uid: uid,
            gid: gid,
            size: 0,
            mtime: mtime ?? currentTimestamp(),
            entryType: .directory,
            userName: userName,
            groupName: groupName
        )

        try writeHeader(header)
    }

    /// Write a file entry header, preparing for streaming content.
    /// After calling this, use `writeContent` to write the file data,
    /// then call `finalizeEntry` when done.
    public func beginFile(
        path: String,
        size: Int64,
        mode: UInt32 = 0o644,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        mtime: Int64? = nil,
        userName: String = "root",
        groupName: String = "root"
    ) throws {
        try ensureNotFinalized()
        try ensureNotWritingContent()

        let header = TarHeader(
            path: path,
            mode: mode,
            uid: uid,
            gid: gid,
            size: size,
            mtime: mtime ?? currentTimestamp(),
            entryType: .regular,
            userName: userName,
            groupName: groupName
        )

        try writeHeader(header)

        currentEntryExpectedSize = size
        currentEntryBytesWritten = 0
        writingEntryContent = true
    }

    /// Write content for the current file entry.
    /// Must be called after `beginFile` and before `finalizeEntry`.
    /// - Parameter buffer: The buffer containing data to write.
    public func writeContent(_ buffer: UnsafeRawBufferPointer) throws {
        try ensureNotFinalized()

        guard writingEntryContent else {
            throw TarWriterError.invalidState("Not currently writing file content")
        }

        try writeAll(buffer)
        currentEntryBytesWritten += Int64(buffer.count)
    }

    /// Finalize the current entry, adding padding if needed.
    public func finalizeEntry() throws {
        try ensureNotFinalized()

        guard writingEntryContent else {
            throw TarWriterError.invalidState("Not currently writing file content")
        }

        if currentEntryBytesWritten != currentEntryExpectedSize {
            throw TarWriterError.sizeMismatch(
                expected: currentEntryExpectedSize,
                actual: currentEntryBytesWritten
            )
        }

        try writePadding(for: currentEntryBytesWritten)

        writingEntryContent = false
        currentEntryBytesWritten = 0
        currentEntryExpectedSize = 0
    }

    /// Write a symbolic link entry.
    public func writeSymlink(
        path: String,
        target: String,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        mtime: Int64? = nil,
        userName: String = "root",
        groupName: String = "root"
    ) throws {
        try ensureNotFinalized()
        try ensureNotWritingContent()

        let header = TarHeader(
            path: path,
            mode: 0o777,
            uid: uid,
            gid: gid,
            size: 0,
            mtime: mtime ?? currentTimestamp(),
            entryType: .symbolicLink,
            linkName: target,
            userName: userName,
            groupName: groupName
        )

        try writeHeader(header)
    }

    /// Write a hard link entry.
    public func writeHardLink(
        path: String,
        target: String,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        mtime: Int64? = nil,
        userName: String = "root",
        groupName: String = "root"
    ) throws {
        try ensureNotFinalized()
        try ensureNotWritingContent()

        let header = TarHeader(
            path: path,
            mode: 0o644,
            uid: uid,
            gid: gid,
            size: 0,
            mtime: mtime ?? currentTimestamp(),
            entryType: .hardLink,
            linkName: target,
            userName: userName,
            groupName: groupName
        )

        try writeHeader(header)
    }

    /// Write a file entry by reading content from a file descriptor.
    /// The file size is determined automatically via fstat.
    /// - Parameters:
    ///   - path: The path for the entry in the archive.
    ///   - source: The file descriptor to read content from.
    ///   - mode: File mode/permissions (default: 0o644).
    ///   - uid: Owner user ID (default: 0).
    ///   - gid: Owner group ID (default: 0).
    ///   - mtime: Modification time as Unix timestamp (default: current time).
    ///   - userName: Owner user name (default: "root").
    ///   - groupName: Owner group name (default: "root").
    public func writeFile(
        path: String,
        from source: FileDescriptor,
        mode: UInt32 = 0o644,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        mtime: Int64? = nil,
        userName: String = "root",
        groupName: String = "root"
    ) throws {
        try ensureNotFinalized()
        try ensureNotWritingContent()

        var statBuf = stat()
        guard fstat(source.rawValue, &statBuf) == 0 else {
            throw TarWriterError.ioError(errno)
        }
        let size = Int64(statBuf.st_size)

        let header = TarHeader(
            path: path,
            mode: mode,
            uid: uid,
            gid: gid,
            size: size,
            mtime: mtime ?? currentTimestamp(),
            entryType: .regular,
            userName: userName,
            groupName: groupName
        )
        try writeHeader(header)

        var remaining = size
        while remaining > 0 {
            let toRead = min(Int(remaining), copyBuffer.count)
            let readBuffer = UnsafeMutableRawBufferPointer(rebasing: copyBuffer[0..<toRead])
            let bytesRead = try source.read(into: readBuffer)
            if bytesRead == 0 {
                throw TarWriterError.sizeMismatch(expected: size, actual: size - remaining)
            }
            try writeAll(UnsafeRawBufferPointer(rebasing: copyBuffer[0..<bytesRead]))
            remaining -= Int64(bytesRead)
        }

        try writePadding(for: size)
    }

    #if canImport(_NIOFileSystem)
    /// Write a file entry by reading content from an async file handle.
    /// The file size is determined automatically via the handle's info.
    public func writeFile(
        path: String,
        from source: some ReadableFileHandleProtocol,
        mode: UInt32 = 0o644,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        mtime: Int64? = nil,
        userName: String = "root",
        groupName: String = "root"
    ) async throws {
        try ensureNotFinalized()
        try ensureNotWritingContent()

        let info = try await source.info()
        let size = Int64(info.size)

        let header = TarHeader(
            path: path,
            mode: mode,
            uid: uid,
            gid: gid,
            size: size,
            mtime: mtime ?? currentTimestamp(),
            entryType: .regular,
            userName: userName,
            groupName: groupName
        )
        try writeHeader(header)

        for try await chunk in source.readChunks(chunkLength: .kibibytes(128)) {
            try chunk.withUnsafeReadableBytes { ptr in
                try writeAll(ptr)
            }
        }

        try writePadding(for: size)
    }
    #endif

    /// Finalize the archive by writing the end-of-archive markers.
    /// After calling this, no more entries can be written.
    public func finalize() throws {
        try ensureNotFinalized()
        try ensureNotWritingContent()

        // Write two empty 512-byte blocks to mark end of archive
        let emptyBlock = [UInt8](repeating: 0, count: TarConstants.blockSize)
        try emptyBlock.withUnsafeBytes { ptr in
            try writeAll(ptr)
            try writeAll(ptr)
        }

        finalized = true
    }

    /// Write a header, automatically adding PAX extended header if needed.
    package func writeHeader(_ header: TarHeader) throws {
        // Check if PAX is needed. If som write the header first,
        if TarPax.requiresPax(header) {
            let paxEntry = TarPax.createPaxEntry(for: header)
            if !paxEntry.isEmpty {
                try paxEntry.withUnsafeBytes { ptr in
                    try writeAll(ptr)
                }
            }

            // Create a truncated version of the header for the regular entry
            var truncatedHeader = header
            if header.path.utf8.count > TarConstants.maxNameLength {
                // Truncate path to last 100 chars for fallback
                let pathBytes = Array(header.path.utf8)
                truncatedHeader.path = String(decoding: pathBytes.suffix(TarConstants.maxNameLength), as: UTF8.self)
            }
            if header.linkName.utf8.count > TarHeaderField.linkNameSize {
                let linkBytes = Array(header.linkName.utf8)
                truncatedHeader.linkName = String(decoding: linkBytes.suffix(TarHeaderField.linkNameSize), as: UTF8.self)
            }
            if header.size > TarConstants.maxTraditionalSize {
                truncatedHeader.size = TarConstants.maxTraditionalSize
            }

            guard let headerBlock = truncatedHeader.serialize() else {
                throw TarWriterError.headerSerializationFailed
            }
            try headerBlock.withUnsafeBytes { ptr in
                try writeAll(ptr)
            }
        } else {
            // No PAX needed, write regular header
            guard let headerBlock = header.serialize() else {
                throw TarWriterError.headerSerializationFailed
            }
            try headerBlock.withUnsafeBytes { ptr in
                try writeAll(ptr)
            }
        }
    }

    /// Write padding to align to 512-byte boundary.
    private func writePadding(for size: Int64) throws {
        let remainder = Int(size % Int64(TarConstants.blockSize))
        if remainder > 0 {
            let padding = [UInt8](repeating: 0, count: TarConstants.blockSize - remainder)
            try padding.withUnsafeBytes { ptr in
                try writeAll(ptr)
            }
        }
    }

    /// Write all bytes from the buffer to the file descriptor.
    private func writeAll(_ buffer: UnsafeRawBufferPointer) throws {
        var totalWritten = 0
        while totalWritten < buffer.count {
            let remaining = UnsafeRawBufferPointer(rebasing: buffer[totalWritten...])
            let written = try fileDescriptor.write(remaining)
            if written == 0 {
                throw TarWriterError.writeZeroBytes
            }
            totalWritten += written
        }
    }

    private func ensureNotFinalized() throws {
        if finalized {
            throw TarWriterError.invalidState("Archive has been finalized")
        }
    }

    private func ensureNotWritingContent() throws {
        if writingEntryContent {
            throw TarWriterError.invalidState("Must call finalizeEntry() before writing another entry")
        }
    }

    private func currentTimestamp() -> Int64 {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return Int64(tv.tv_sec)
    }
}
