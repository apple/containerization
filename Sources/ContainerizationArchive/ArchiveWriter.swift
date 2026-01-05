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

/// A class responsible for writing archives in various formats.
public final class ArchiveWriter {
    var underlying: OpaquePointer!
    var delegate: FileArchiveWriterDelegate?

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

    /// Initialize a new `ArchiveWriter` with the given configuration and specified delegate.
    private convenience init(configuration: ArchiveWriterConfiguration, delegate: FileArchiveWriterDelegate) throws {
        try self.init(configuration: configuration)
        self.delegate = delegate
        try self.open()
    }

    private convenience init(configuration: ArchiveWriterConfiguration, file: URL) throws {
        try self.init(configuration: configuration, delegate: FileArchiveWriterDelegate(url: file))
    }

    /// Initialize a new `ArchiveWriter` for writing into the specified file with the given configuration options.
    public convenience init(format: Format, filter: Filter, options: [Options] = [], file: URL) throws {
        try self.init(
            configuration: .init(format: format, filter: filter), delegate: FileArchiveWriterDelegate(url: file))
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

extension ArchiveWriter {
    fileprivate func open() throws {
        guard let underlying = underlying else { throw ArchiveError.noUnderlyingArchive }
        // TODO: to be or not to be retained, that is the question
        let pointerToSelf = Unmanaged.passUnretained(self).toOpaque()

        let res = archive_write_open2(
            underlying,
            pointerToSelf,
            /// The open callback is invoked by archive_write_open().  It should return ARCHIVE_OK if the underlying file or data source is successfully opened.  If the open fails, it should call archive_set_error() to register an error code and message and return ARCHIVE_FATAL.  Please note that
            /// if open fails, close is not called and resources must be freed inside the open callback or with the free callback.
            { underlying, pointerToSelf in
                do {
                    guard let pointerToSelf = pointerToSelf else {
                        throw ArchiveError.noArchiveInCallback
                    }
                    let archive: ArchiveWriter = Unmanaged.fromOpaque(pointerToSelf).takeUnretainedValue()
                    guard let delegate = archive.delegate else {
                        throw ArchiveError.noDelegateConfigured
                    }
                    try delegate.open(archive: archive)
                    return ARCHIVE_OK
                } catch {
                    archive_set_error_wrapper(underlying, ARCHIVE_FATAL, "\(error)")
                    return ARCHIVE_FATAL
                }
            },
            /// The write callback is invoked whenever the library needs to write raw bytes to the archive.  For correct blocking, each call to the write callback function should translate into a single write(2) system call.  This is especially critical when writing archives to tape drives.  On
            /// success, the write callback should return the number of bytes actually written.  On error, the callback should invoke archive_set_error() to register an error code and message and return -1.
            { underlying, pointerToSelf, dataPointer, count in
                do {
                    guard let pointerToSelf = pointerToSelf else {
                        throw ArchiveError.noArchiveInCallback
                    }
                    let archive: ArchiveWriter = Unmanaged.fromOpaque(pointerToSelf).takeUnretainedValue()
                    guard let delegate = archive.delegate else {
                        throw ArchiveError.noDelegateConfigured
                    }
                    return try delegate.write(
                        archive: archive, buffer: UnsafeRawBufferPointer(start: dataPointer, count: count))
                } catch {
                    archive_set_error_wrapper(underlying, ARCHIVE_FATAL, "\(error)")
                    return -1
                }
            },
            /// The close callback is invoked by archive_close when the archive processing is complete. If the open callback fails, the close callback is not invoked.  The callback should return ARCHIVE_OK on success.  On failure, the callback should invoke archive_set_error() to register an
            /// error code and message and return
            { underlying, pointerToSelf in
                do {
                    guard let pointerToSelf = pointerToSelf else {
                        throw ArchiveError.noArchiveInCallback
                    }
                    let archive: ArchiveWriter = Unmanaged.fromOpaque(pointerToSelf).takeUnretainedValue()
                    guard let delegate = archive.delegate else {
                        throw ArchiveError.noDelegateConfigured
                    }
                    try delegate.close(archive: archive)
                    return ARCHIVE_OK
                } catch {
                    archive_set_error_wrapper(underlying, ARCHIVE_FATAL, "\(error)")
                    return ARCHIVE_FATAL
                }
            },
            /// The free callback is always invoked on archive_free.  The return code of this callback is not processed.
            { underlying, pointerToSelf in
                do {
                    guard let pointerToSelf = pointerToSelf else {
                        throw ArchiveError.noArchiveInCallback
                    }
                    let archive: ArchiveWriter = Unmanaged.fromOpaque(pointerToSelf).takeUnretainedValue()
                    guard let delegate = archive.delegate else {
                        throw ArchiveError.noDelegateConfigured
                    }
                    delegate.free(archive: archive)

                    // TODO: should we balance the Unmanaged refcount here? Need to test for leaks.
                    return ARCHIVE_OK
                } catch {
                    archive_set_error_wrapper(underlying, ARCHIVE_FATAL, "\(error)")
                    return ARCHIVE_FATAL
                }
            }
        )

        try wrap(res, ArchiveError.unableToOpenArchive, underlying: underlying)
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

        let result = archive_write_data(underlying, data.baseAddress, data.count)
        guard result >= 0 else {
            throw ArchiveError.unableToWriteData(result)
        }
    }
}

extension ArchiveWriter {
    /// Recursively archives the content of a directory. Regular files, symlinks and directories are added into the archive.
    /// Note: Symlinks are added to the archive if both the source and target for the symlink are both contained in the top level directory.
    public func archiveDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        var resourceKeys = Set<URLResourceKey>([
            .fileSizeKey, .fileResourceTypeKey,
            .creationDateKey, .contentAccessDateKey, .contentModificationDateKey,
        ])
        #if os(macOS)
        resourceKeys.insert(.fileSecurityKey)
        #endif

        guard let directoryEnumerator = fm.enumerator(at: dir, includingPropertiesForKeys: Array(resourceKeys), options: .producesRelativePathURLs) else {
            throw POSIXError(.ENOTDIR)
        }
        for case let fileURL as URL in directoryEnumerator {
            var mode = mode_t()
            var uid = uid_t()
            var gid = gid_t()
            let resourceValues = try fileURL.resourceValues(forKeys: resourceKeys)
            guard let type = resourceValues.fileResourceType else {
                throw ArchiveError.failedToGetProperty(fileURL.path(), .fileResourceTypeKey)
            }
            let allowedTypes: [URLFileResourceType] = [.directory, .regular, .symbolicLink]
            guard allowedTypes.contains(type) else {
                continue
            }
            var size: Int64 = 0
            let entry = WriteEntry()
            if type == .regular {
                guard let _size = resourceValues.fileSize else {
                    throw ArchiveError.failedToGetProperty(fileURL.path(), .fileSizeKey)
                }
                size = Int64(_size)
            } else if type == .symbolicLink {
                let target = fileURL.resolvingSymlinksInPath().absoluteString
                let root = dir.absoluteString
                guard target.hasPrefix(root) else {
                    continue
                }
                let linkTarget = target.dropFirst(root.count + 1)
                entry.symlinkTarget = String(linkTarget)
            }

            guard let created = resourceValues.creationDate else {
                throw ArchiveError.failedToGetProperty(fileURL.path(), .creationDateKey)
            }
            guard let access = resourceValues.contentAccessDate else {
                throw ArchiveError.failedToGetProperty(fileURL.path(), .contentAccessDateKey)
            }
            guard let modified = resourceValues.contentModificationDate else {
                throw ArchiveError.failedToGetProperty(fileURL.path(), .contentModificationDateKey)
            }

            #if os(macOS)
            guard let perms = resourceValues.fileSecurity else {
                throw ArchiveError.failedToGetProperty(fileURL.path(), .fileSecurityKey)
            }
            CFFileSecurityGetMode(perms, &mode)
            CFFileSecurityGetOwner(perms, &uid)
            CFFileSecurityGetGroup(perms, &gid)
            #else
            let path = fileURL.path()
            var statInfo = stat()
            guard lstat(path, &statInfo) == 0 else {
                let err = POSIXErrorCode(rawValue: errno)!
                throw POSIXError(err)
            }
            mode = statInfo.st_mode
            uid = statInfo.st_uid
            gid = statInfo.st_gid
            #endif

            entry.path = fileURL.relativePath
            entry.size = size
            entry.creationDate = created
            entry.modificationDate = modified
            entry.contentAccessDate = access
            entry.fileType = type
            entry.group = gid
            entry.owner = uid
            entry.permissions = mode
            if type == .regular {
                let p = dir.appending(path: fileURL.relativePath)
                let data = try Data(contentsOf: p, options: .uncached)
                try self.writeEntry(entry: entry, data: data)
            } else {
                try self.writeHeader(entry: entry)
            }
        }
    }
}
