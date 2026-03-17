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
import SystemPackage

/// A class responsible for writing archives in various formats.
public final class ArchiveWriter {
    var underlying: OpaquePointer!

    /// Initialize a new `ArchiveWriter` with the given configuration.
    /// This method attempts to initialize an empty archive in memory, failing which it throws a `unableToCreateArchive` error.
    public init(configuration: ArchiveWriterConfiguration) throws {
        // because for some bizarre reason, UTF8 paths won't work unless this process explicitly sets a locale like en_US.UTF-8
        try Self.attemptSetLocales(locales: configuration.locales)

        guard let underlying = archive_write_new() else { throw ArchiveError.unableToCreateArchive }
        self.underlying = underlying

        try setFormat(configuration.format)
        try addFilter(configuration.filter)
        try setOptions(configuration.options)
    }

    /// Initialize a new `ArchiveWriter` for writing into the specified file with the given configuration options.
    public convenience init(format: Format, filter: Filter, options: [Options] = [], locales: [String] = ArchiveWriterConfiguration.defaultLocales, file: URL) throws {
        let config = ArchiveWriterConfiguration(
            format: format,
            filter: filter,
            options: options,
            locales: locales
        )
        try self.init(configuration: config)
        try self.open(file: file)
    }

    /// Opens the given file for writing data into
    public func open(file: URL) throws {
        guard let underlying = underlying else { throw ArchiveError.noUnderlyingArchive }
        let res = archive_write_open_filename(underlying, file.path)
        try wrap(res, ArchiveError.unableToOpenArchive, underlying: underlying)
    }

    /// Opens the given fd for writing data into
    public func open(fileDescriptor: Int32) throws {
        guard let underlying = underlying else { throw ArchiveError.noUnderlyingArchive }
        let res = archive_write_open_fd(underlying, fileDescriptor)
        try wrap(res, ArchiveError.unableToOpenArchive, underlying: underlying)
    }

    /// Performs any necessary finalizations on the archive and releases resources.
    public func finishEncoding() throws {
        if let u = underlying {
            let r = archive_free(u)
            do {
                try wrap(r, ArchiveError.unableToCloseArchive, underlying: underlying)
                underlying = nil
            } catch {
                underlying = nil
                throw error
            }
        }
    }

    deinit {
        if let u = underlying {
            archive_free(u)
            underlying = nil
        }
    }

    private static func attemptSetLocales(locales: [String]) throws {
        for locale in locales {
            if setlocale(LC_ALL, locale) != nil {
                return
            }
        }
        throw ArchiveError.failedToSetLocale(locales: locales)
    }
}

public class ArchiveWriterTransaction {
    private let writer: ArchiveWriter

    fileprivate init(writer: ArchiveWriter) {
        self.writer = writer
    }

    public func writeHeader(entry: WriteEntry) throws {
        try writer.writeHeader(entry: entry)
    }

    public func writeChunk(data: UnsafeRawBufferPointer) throws {
        try writer.writeData(data: data)
    }

    public func finish() throws {
        try writer.finishEntry()
    }
}

extension ArchiveWriter {
    public func makeTransactionWriter() -> ArchiveWriterTransaction {
        ArchiveWriterTransaction(writer: self)
    }

    /// Create a new entry in the archive with the given properties.
    /// - Parameters:
    ///   - entry: A `WriteEntry` object describing the metadata of the entry to be created
    ///            (e.g., name, modification date, permissions).
    ///   - data: The `Data` object containing the content for the new entry.
    public func writeEntry(entry: WriteEntry, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            try writeEntry(entry: entry, data: bytes)
        }
    }

    /// Creates a new entry in the archive with the given properties.
    ///
    /// This method performs the following:
    /// 1. Writes the archive header using the provided `WriteEntry` metadata.
    /// 2. Writes the content from the `UnsafeRawBufferPointer` into the archive.
    /// 3. Finalizes the entry in the archive.
    ///
    /// - Parameters:
    ///   - entry: A `WriteEntry` object describing the metadata of the entry to be created
    ///            (e.g., name, modification date, permissions, type).
    ///   - data: An optional `UnsafeRawBufferPointer` containing the raw bytes for the new entry's
    ///           content. Pass `nil` for entries that do not have content data (e.g., directories, symlinks).
    public func writeEntry(entry: WriteEntry, data: UnsafeRawBufferPointer?) throws {
        try writeHeader(entry: entry)
        if let data = data {
            try writeData(data: data)
        }
        try finishEntry()
    }

    fileprivate func writeHeader(entry: WriteEntry) throws {
        guard let underlying = self.underlying else { throw ArchiveError.noUnderlyingArchive }

        try wrap(
            archive_write_header(underlying, entry.underlying), ArchiveError.unableToWriteEntryHeader,
            underlying: underlying)
    }

    fileprivate func finishEntry() throws {
        guard let underlying = self.underlying else { throw ArchiveError.noUnderlyingArchive }

        archive_write_finish_entry(underlying)
    }

    fileprivate func writeData(data: UnsafeRawBufferPointer) throws {
        guard let underlying = self.underlying else { throw ArchiveError.noUnderlyingArchive }

        var offset = 0
        while offset < data.count {
            guard let baseAddress = data.baseAddress?.advanced(by: offset) else {
                throw ArchiveError.invalidBaseAddressArchiveWrite
            }
            let result = archive_write_data(underlying, baseAddress, data.count - offset)
            guard result > 0 else {
                throw ArchiveError.unableToWriteData(result)
            }
            offset += Int(result)
        }
    }
}

extension ArchiveWriter {
    /// Recursively archives the content of a directory. Regular files, symlinks and directories are added into the archive.
    /// Note: Symlinks are added to the archive if both the source and target for the symlink are both contained in the top level directory.
    public func archiveDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        let dirPath = FilePath(dir.path)

        guard let enumerator = fm.enumerator(atPath: dirPath.string) else {
            throw POSIXError(.ENOTDIR)
        }

        // Emit a leading "./" entry for the root directory, matching GNU/BSD tar behavior.
        var rootStat = stat()
        guard lstat(dirPath.string, &rootStat) == 0 else {
            let err = POSIXErrorCode(rawValue: errno) ?? .EINVAL
            throw ArchiveError.failedToExtractArchive("lstat failed for '\(dirPath)': \(POSIXError(err))")
        }
        let rootEntry = WriteEntry()
        rootEntry.path = "./"
        rootEntry.size = 0
        rootEntry.fileType = .directory
        rootEntry.owner = rootStat.st_uid
        rootEntry.group = rootStat.st_gid
        rootEntry.permissions = rootStat.st_mode
        #if os(macOS)
        rootEntry.creationDate = Date(timeIntervalSince1970: Double(rootStat.st_ctimespec.tv_sec))
        rootEntry.contentAccessDate = Date(timeIntervalSince1970: Double(rootStat.st_atimespec.tv_sec))
        rootEntry.modificationDate = Date(timeIntervalSince1970: Double(rootStat.st_mtimespec.tv_sec))
        #else
        rootEntry.creationDate = Date(timeIntervalSince1970: Double(rootStat.st_ctim.tv_sec))
        rootEntry.contentAccessDate = Date(timeIntervalSince1970: Double(rootStat.st_atim.tv_sec))
        rootEntry.modificationDate = Date(timeIntervalSince1970: Double(rootStat.st_mtim.tv_sec))
        #endif
        try self.writeHeader(entry: rootEntry)

        for case let relativePath as String in enumerator {
            let fullPath = dirPath.appending(relativePath)

            var statInfo = stat()
            guard lstat(fullPath.string, &statInfo) == 0 else {
                let errNo = errno
                let err = POSIXErrorCode(rawValue: errNo) ?? .EINVAL
                throw ArchiveError.failedToExtractArchive("lstat failed for '\(fullPath)': \(POSIXError(err))")
            }

            let mode = statInfo.st_mode
            let uid = statInfo.st_uid
            let gid = statInfo.st_gid
            var size: Int64 = 0
            let type: URLFileResourceType

            if (mode & S_IFMT) == S_IFREG {
                type = .regular
                size = Int64(statInfo.st_size)
            } else if (mode & S_IFMT) == S_IFDIR {
                type = .directory
            } else if (mode & S_IFMT) == S_IFLNK {
                type = .symbolicLink
            } else {
                continue
            }

            #if os(macOS)
            let created = Date(timeIntervalSince1970: Double(statInfo.st_ctimespec.tv_sec))
            let access = Date(timeIntervalSince1970: Double(statInfo.st_atimespec.tv_sec))
            let modified = Date(timeIntervalSince1970: Double(statInfo.st_mtimespec.tv_sec))
            #else
            let created = Date(timeIntervalSince1970: Double(statInfo.st_ctim.tv_sec))
            let access = Date(timeIntervalSince1970: Double(statInfo.st_atim.tv_sec))
            let modified = Date(timeIntervalSince1970: Double(statInfo.st_mtim.tv_sec))
            #endif

            let entry = WriteEntry()
            if type == .symbolicLink {
                let targetPath = try fm.destinationOfSymbolicLink(atPath: fullPath.string)
                // Resolve the target relative to the symlink's parent, not the archive root.
                let symlinkParent = fullPath.removingLastComponent()
                let resolvedFull = symlinkParent.appending(targetPath).lexicallyNormalized()
                guard resolvedFull.starts(with: dirPath) else {
                    continue
                }
                entry.symlinkTarget = targetPath
            }

            entry.path = relativePath
            entry.size = size
            entry.creationDate = created
            entry.modificationDate = modified
            entry.contentAccessDate = access
            entry.fileType = type
            entry.group = gid
            entry.owner = uid
            entry.permissions = mode
            if type == .regular {
                guard let fileHandle = FileHandle(forReadingAtPath: fullPath.string) else {
                    throw POSIXError(.ENOENT)
                }
                defer { fileHandle.closeFile() }
                try self.writeHeader(entry: entry)
                let chunkSize = 4 * 1024 * 1024
                while true {
                    let chunk = fileHandle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    try chunk.withUnsafeBytes { bytes in
                        try self.writeData(data: bytes)
                    }
                }
                try self.finishEntry()
            } else {
                try self.writeEntry(entry: entry, data: nil)
            }
        }
    }
}
