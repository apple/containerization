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

import CArchive
import Foundation

/// A protocol for reading data in chunks, compatible with both `InputStream` and zero-allocation archive readers.
public protocol ReadableStream {
    /// Reads up to `maxLength` bytes into the provided buffer.
    /// Returns the number of bytes actually read, 0 for EOF, or -1 for error.
    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int
}

extension InputStream: ReadableStream {}

/// Small wrapper type to read data from an archive entry.
public struct ArchiveEntryReader: ReadableStream {
    private weak var reader: ArchiveReader?

    init(reader: ArchiveReader) {
        self.reader = reader
    }

    /// Reads up to `maxLength` bytes into the provided buffer.
    /// Returns the number of bytes actually read, 0 for EOF, or -1 for error.
    public func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        guard let archive = reader?.underlying else { return -1 }
        let bytesRead = archive_read_data(archive, buffer, maxLength)
        return bytesRead < 0 ? -1 : bytesRead
    }
}

/// A class responsible for reading entries from an archive file.
public final class ArchiveReader {
    /// A pointer to the underlying `archive` C structure.
    var underlying: OpaquePointer?
    /// The file handle associated with the archive file being read.
    let fileHandle: FileHandle?

    /// Initializes an `ArchiveReader` to read from a specified file URL with an explicit `Format` and `Filter`.
    /// Note: This method must be used when it is known that the archive at the specified URL follows the specified
    /// `Format` and `Filter`.
    public convenience init(format: Format, filter: Filter, file: URL) throws {
        let fileHandle = try FileHandle(forReadingFrom: file)
        try self.init(format: format, filter: filter, fileHandle: fileHandle)
    }

    /// Initializes an `ArchiveReader` to read from the provided file descriptor with an explicit `Format` and `Filter`.
    /// Note: This method must be used when it is known that the archive pointed to by the file descriptor follows the specified
    /// `Format` and `Filter`.
    public init(format: Format, filter: Filter, fileHandle: FileHandle) throws {
        self.underlying = archive_read_new()
        self.fileHandle = fileHandle

        try archive_read_set_format(underlying, format.code)
            .checkOk(elseThrow: .unableToSetFormat(format.code, format))
        try archive_read_append_filter(underlying, filter.code)
            .checkOk(elseThrow: .unableToAddFilter(filter.code, filter))

        let fd = fileHandle.fileDescriptor
        try archive_read_open_fd(underlying, fd, 4096)
            .checkOk(elseThrow: { .unableToOpenArchive($0) })
    }

    /// Initialize the `ArchiveReader` to read from a specified file URL
    /// by trying to auto determine the archives `Format` and `Filter`.
    public init(file: URL) throws {
        self.underlying = archive_read_new()
        let fileHandle = try FileHandle(forReadingFrom: file)
        self.fileHandle = fileHandle
        try archive_read_support_filter_all(underlying)
            .checkOk(elseThrow: .failedToDetectFilter)
        try archive_read_support_format_all(underlying)
            .checkOk(elseThrow: .failedToDetectFormat)
        let fd = fileHandle.fileDescriptor
        try archive_read_open_fd(underlying, fd, 4096)
            .checkOk(elseThrow: { .unableToOpenArchive($0) })
    }

    deinit {
        archive_read_free(underlying)
        try? fileHandle?.close()
    }
}

extension CInt {
    fileprivate func checkOk(elseThrow error: @autoclosure () -> ArchiveError) throws {
        guard self == ARCHIVE_OK else { throw error() }
    }
    fileprivate func checkOk(elseThrow error: (CInt) -> ArchiveError) throws {
        guard self == ARCHIVE_OK else { throw error(self) }
    }

}

extension ArchiveReader: Sequence {
    public func makeIterator() -> Iterator {
        Iterator(reader: self)
    }

    public struct Iterator: IteratorProtocol {
        var reader: ArchiveReader

        public mutating func next() -> (WriteEntry, Data)? {
            let entry = WriteEntry()
            let result = archive_read_next_header2(reader.underlying, entry.underlying)
            if result == ARCHIVE_EOF {
                return nil
            }
            let data = reader.readDataForEntry(entry)
            return (entry, data)
        }
    }

    /// Returns an iterator that yields archive entries.
    public func makeStreamingIterator() -> StreamingIterator {
        StreamingIterator(reader: self)
    }

    public struct StreamingIterator: Sequence, IteratorProtocol {
        var reader: ArchiveReader

        public func makeIterator() -> StreamingIterator {
            self
        }

        public mutating func next() -> (WriteEntry, ArchiveEntryReader)? {
            let entry = WriteEntry()
            let result = archive_read_next_header2(reader.underlying, entry.underlying)
            if result == ARCHIVE_EOF {
                return nil
            }
            let streamReader = ArchiveEntryReader(reader: reader)
            return (entry, streamReader)
        }
    }

    internal func readDataForEntry(_ entry: WriteEntry) -> Data {
        let bufferSize = Int(Swift.min(entry.size ?? 4096, 4096))
        var entry = Data()
        var part = Data(count: bufferSize)
        while true {
            let c = part.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return archive_read_data(self.underlying, baseAddress, buffer.count)
            }
            guard c > 0 else { break }
            part.count = c
            entry.append(part)
        }
        return entry
    }
}

extension ArchiveReader {
    public convenience init(name: String, bundle: Data, tempDirectoryBaseName: String? = nil) throws {
        let baseName = tempDirectoryBaseName ?? "Unarchiver"
        let url = createTemporaryDirectory(baseName: baseName)!.appendingPathComponent(name)
        try bundle.write(to: url, options: .atomic)
        try self.init(format: .zip, filter: .none, file: url)
    }

    /// Extracts the contents of an archive to the provided directory.
    /// Currently only handles regular files and directories present in the archive.
    public func extractContents(to directory: URL) throws {
        let fm = FileManager.default
        var foundEntry = false
        for (entry, data) in self {
            guard let p = entry.path else { continue }
            foundEntry = true
            let type = entry.fileType
            let target = directory.appending(path: p)
            switch type {
            case .regular:
                try data.write(to: target, options: .atomic)
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .symbolicLink:
                guard let symlinkTarget = entry.symlinkTarget, let linkTargetURL = URL(string: symlinkTarget, relativeTo: target) else {
                    continue
                }
                try fm.createSymbolicLink(at: target, withDestinationURL: linkTargetURL)
            default:
                continue
            }
            chmod(target.path(), entry.permissions)
            if let owner = entry.owner, let group = entry.group {
                chown(target.path(), owner, group)
            }
        }
        guard foundEntry else {
            throw ArchiveError.failedToExtractArchive("no entries found in archive")
        }
    }

    /// This method extracts a given file from the archive.
    /// This operation modifies the underlying file descriptor's position within the archive,
    /// meaning subsequent reads will start from a new location.
    /// To reset the underlying file descriptor to the beginning of the archive, close and
    /// reopen the archive.
    public func extractFile(path: String) throws -> (WriteEntry, Data) {
        let entry = WriteEntry()
        while archive_read_next_header2(self.underlying, entry.underlying) != ARCHIVE_EOF {
            guard let entryPath = entry.path else { continue }
            let trimCharSet = CharacterSet(charactersIn: "./")
            let trimmedEntry = entryPath.trimmingCharacters(in: trimCharSet)
            let trimmedRequired = path.trimmingCharacters(in: trimCharSet)
            guard trimmedEntry == trimmedRequired else { continue }
            let data = readDataForEntry(entry)
            return (entry, data)
        }
        throw ArchiveError.failedToExtractArchive(" \(path) not found in archive")
    }
}
