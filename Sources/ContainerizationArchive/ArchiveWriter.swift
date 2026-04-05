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
    private static let chunkSize = 4 * 1024 * 1024

    var underlying: OpaquePointer?

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
        guard let u = underlying else { return }
        underlying = nil
        let r = archive_free(u)
        guard r == ARCHIVE_OK else {
            throw ArchiveError.unableToCloseArchive(r)
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

/// Represents a host filesystem entry to be archived at a specific path.
public struct ArchiveSourceEntry: Sendable {
    /// Path to the item on the host filesystem.
    public let pathOnHost: URL
    /// Path to use for the entry inside the archive.
    public let pathInArchive: String
    /// Optional owner override for the archived entry.
    public let owner: uid_t?
    /// Optional group override for the archived entry.
    public let group: gid_t?
    /// Optional permissions override for the archived entry.
    public let permissions: mode_t?

    public init(
        pathOnHost: URL,
        pathInArchive: String,
        owner: uid_t? = nil,
        group: gid_t? = nil,
        permissions: mode_t? = nil
    ) {
        self.pathOnHost = pathOnHost
        self.pathInArchive = pathInArchive
        self.owner = owner
        self.group = group
        self.permissions = permissions
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
    /// Archives an explicit, ordered list of host filesystem entries.
    public func archiveEntries(_ entries: [ArchiveSourceEntry]) throws {
        let archivedPathsByHostPath = entries.reduce(into: [String: [String]]()) { result, entry in
            result[entry.pathOnHost.path, default: []].append(entry.pathInArchive)
        }

        for source in entries {
            guard let entry = try Self.makeEntry(from: source, archivedPathsByHostPath: archivedPathsByHostPath) else {
                throw ArchiveError.failedToCreateArchive("unsupported file type at '\(source.pathOnHost.path)'")
            }
            try self.writeSourceEntry(entry: entry, sourcePath: source.pathOnHost.path)
        }
    }

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
            throw ArchiveError.failedToCreateArchive("lstat failed for '\(dirPath)': \(POSIXError(err))")
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
                throw ArchiveError.failedToCreateArchive("lstat failed for '\(fullPath)': \(POSIXError(err))")
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
                guard let resolvedFull = Self.resolveArchivedDirectorySymlinkTarget(
                    targetPath,
                    symlinkPath: fullPath
                ) else {
                    continue
                }
                guard resolvedFull.starts(with: dirPath) else {
                    continue
                }
                entry.symlinkTarget = Self.rewriteArchivedDirectorySymlinkTarget(
                    targetPath,
                    sourceEntryPath: relativePath,
                    sourceRoot: dirPath,
                    resolvedTargetPath: resolvedFull
                )
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
                let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunkSize, alignment: 1)
                guard let baseAddress = buf.baseAddress else {
                    throw ArchiveError.failedToCreateArchive("cannot create temporary buffer of size \(Self.chunkSize)")
                }
                defer { buf.deallocate() }
                let fd = Foundation.open(fullPath.string, O_RDONLY)
                guard fd >= 0 else {
                    let err = POSIXErrorCode(rawValue: errno) ?? .EINVAL
                    throw ArchiveError.failedToCreateArchive("cannot open file \(fullPath.string) for reading: \(err)")
                }
                defer { close(fd) }
                try self.writeHeader(entry: entry)
                while true {
                    let n = read(fd, baseAddress, Self.chunkSize)
                    if n == 0 { break }
                    if n < 0 {
                        let err = POSIXErrorCode(rawValue: errno) ?? .EIO
                        throw ArchiveError.failedToCreateArchive("failed to read from file \(fullPath.string): \(err)")
                    }
                    try self.writeData(data: UnsafeRawBufferPointer(start: baseAddress, count: n))
                }
                try self.finishEntry()
            } else {
                try self.writeEntry(entry: entry, data: nil)
            }
        }
    }

    private struct FileStatus {
        enum EntryType {
            case directory
            case regular
            case symbolicLink
        }

        let entryType: EntryType
        let permissions: mode_t
        let size: Int64
        let owner: uid_t
        let group: gid_t
        let creationDate: Date?
        let contentAccessDate: Date?
        let modificationDate: Date?
        let symlinkTarget: String?
    }

    private func writeSourceEntry(entry: WriteEntry, sourcePath: String) throws {
        guard entry.fileType == .regular else {
            try self.writeEntry(entry: entry, data: nil)
            return
        }

        let writer = self.makeTransactionWriter()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunkSize, alignment: 1)
        guard let baseAddress = buffer.baseAddress else {
            buffer.deallocate()
            throw ArchiveError.failedToCreateArchive("cannot create temporary buffer of size \(Self.chunkSize)")
        }
        defer { buffer.deallocate() }

        let fd = Foundation.open(sourcePath, O_RDONLY)
        guard fd >= 0 else {
            let err = POSIXErrorCode(rawValue: errno) ?? .EINVAL
            throw ArchiveError.failedToCreateArchive("cannot open file \(sourcePath) for reading: \(err)")
        }
        defer { close(fd) }

        try writer.writeHeader(entry: entry)
        while true {
            let bytesRead = read(fd, baseAddress, Self.chunkSize)
            if bytesRead == 0 {
                break
            }
            if bytesRead < 0 {
                let err = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw ArchiveError.failedToCreateArchive("failed to read from file \(sourcePath): \(err)")
            }
            try writer.writeChunk(data: UnsafeRawBufferPointer(start: baseAddress, count: bytesRead))
        }
        try writer.finish()
    }

    private static func makeEntry(
        from source: ArchiveSourceEntry,
        archivedPathsByHostPath: [String: [String]]
    ) throws -> WriteEntry? {
        guard let status = try Self.fileStatus(atPath: source.pathOnHost.path) else {
            return nil
        }
        let entry = WriteEntry()

        switch status.entryType {
        case .directory:
            entry.fileType = .directory
            entry.size = 0
        case .regular:
            entry.fileType = .regular
            entry.size = status.size
        case .symbolicLink:
            entry.fileType = .symbolicLink
            entry.size = 0
            entry.symlinkTarget = Self.rewriteArchivedAbsoluteSymlinkTarget(
                status.symlinkTarget ?? "",
                sourceEntryPath: source.pathInArchive,
                archivedPathsByHostPath: archivedPathsByHostPath
            )
        }

        entry.path = source.pathInArchive
        entry.permissions = source.permissions ?? status.permissions
        entry.owner = source.owner ?? status.owner
        entry.group = source.group ?? status.group
        entry.creationDate = status.creationDate
        entry.contentAccessDate = status.contentAccessDate
        entry.modificationDate = status.modificationDate
        return entry
    }

    private static func fileStatus(atPath path: String) throws -> FileStatus? {
        try path.withCString { fileSystemPath in
            var status = stat()
            guard lstat(fileSystemPath, &status) == 0 else {
                let err = POSIXErrorCode(rawValue: errno) ?? .EINVAL
                throw ArchiveError.failedToCreateArchive("lstat failed for '\(path)': \(POSIXError(err))")
            }

            let mode = status.st_mode & S_IFMT
            let entryType: FileStatus.EntryType
            let symlinkTarget: String?

            switch mode {
            case S_IFDIR:
                entryType = .directory
                symlinkTarget = nil
            case S_IFREG:
                entryType = .regular
                symlinkTarget = nil
            case S_IFLNK:
                entryType = .symbolicLink
                symlinkTarget = try Self.symlinkTarget(fileSystemPath: fileSystemPath, path: path, sizeHint: Int(status.st_size))
            default:
                return nil
            }

            return FileStatus(
                entryType: entryType,
                permissions: status.st_mode & 0o7777,
                size: Int64(status.st_size),
                owner: status.st_uid,
                group: status.st_gid,
                creationDate: Self.creationDate(from: status),
                contentAccessDate: Self.contentAccessDate(from: status),
                modificationDate: Self.modificationDate(from: status),
                symlinkTarget: symlinkTarget
            )
        }
    }

    private static func symlinkTarget(fileSystemPath: UnsafePointer<CChar>, path: String, sizeHint: Int) throws -> String {
        let capacity = max(sizeHint + 1, Int(PATH_MAX))
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        let count = readlink(fileSystemPath, buffer, capacity - 1)
        guard count >= 0 else {
            let err = POSIXErrorCode(rawValue: errno) ?? .EINVAL
            throw ArchiveError.failedToCreateArchive("readlink failed for '\(path)': \(POSIXError(err))")
        }

        buffer[count] = 0
        return String(cString: buffer)
    }

    private static func creationDate(from status: stat) -> Date? {
        #if os(macOS)
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_ctimespec.tv_sec)
                + TimeInterval(status.st_ctimespec.tv_nsec) / 1_000_000_000
        )
        #else
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_ctim.tv_sec)
                + TimeInterval(status.st_ctim.tv_nsec) / 1_000_000_000
        )
        #endif
    }

    private static func contentAccessDate(from status: stat) -> Date? {
        #if os(macOS)
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_atimespec.tv_sec)
                + TimeInterval(status.st_atimespec.tv_nsec) / 1_000_000_000
        )
        #else
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_atim.tv_sec)
                + TimeInterval(status.st_atim.tv_nsec) / 1_000_000_000
        )
        #endif
    }

    private static func modificationDate(from status: stat) -> Date? {
        #if os(macOS)
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        #else
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_mtim.tv_sec)
                + TimeInterval(status.st_mtim.tv_nsec) / 1_000_000_000
        )
        #endif
    }

    private static func rewriteArchivedAbsoluteSymlinkTarget(
        _ symlinkTarget: String,
        sourceEntryPath: String,
        archivedPathsByHostPath: [String: [String]]
    ) -> String {
        guard symlinkTarget.hasPrefix("/") else {
            return symlinkTarget
        }

        let targetPath = URL(fileURLWithPath: symlinkTarget)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard let targetArchivePaths = archivedPathsByHostPath[targetPath],
            targetArchivePaths.count == 1,
            let targetArchivePath = targetArchivePaths.first
        else {
            return symlinkTarget
        }

        let sourceDirectory = (sourceEntryPath as NSString).deletingLastPathComponent
        return Self.relativeArchivePath(fromDirectory: sourceDirectory, to: targetArchivePath)
    }

    private static func resolveArchivedDirectorySymlinkTarget(
        _ symlinkTarget: String,
        symlinkPath: FilePath
    ) -> FilePath? {
        if symlinkTarget.hasPrefix("/") {
            let resolvedTargetPath = URL(fileURLWithPath: symlinkTarget)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            return FilePath(resolvedTargetPath)
        }

        let symlinkParent = symlinkPath.removingLastComponent()
        return symlinkParent.appending(symlinkTarget).lexicallyNormalized()
    }

    private static func rewriteArchivedDirectorySymlinkTarget(
        _ symlinkTarget: String,
        sourceEntryPath: String,
        sourceRoot: FilePath,
        resolvedTargetPath: FilePath
    ) -> String {
        guard symlinkTarget.hasPrefix("/"),
            let targetArchivePath = Self.relativePath(path: resolvedTargetPath.string, within: sourceRoot.string)
        else {
            return symlinkTarget
        }

        let sourceDirectory = (sourceEntryPath as NSString).deletingLastPathComponent
        return Self.relativeArchivePath(fromDirectory: sourceDirectory, to: targetArchivePath)
    }

    private static func relativePath(path: String, within root: String) -> String? {
        if path == root {
            return ""
        }

        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(rootPrefix) else {
            return nil
        }
        return String(path.dropFirst(rootPrefix.count))
    }

    private static func relativeArchivePath(fromDirectory: String, to path: String) -> String {
        let fromComponents = Self.archivePathComponents(fromDirectory)
        let toComponents = Self.archivePathComponents(path)

        var commonPrefixCount = 0
        while commonPrefixCount < fromComponents.count,
            commonPrefixCount < toComponents.count,
            fromComponents[commonPrefixCount] == toComponents[commonPrefixCount]
        {
            commonPrefixCount += 1
        }

        let upwardTraversal = Array(repeating: "..", count: fromComponents.count - commonPrefixCount)
        let remainder = Array(toComponents.dropFirst(commonPrefixCount))
        let relativeComponents = upwardTraversal + remainder
        return relativeComponents.isEmpty ? "." : relativeComponents.joined(separator: "/")
    }

    private static func archivePathComponents(_ path: String) -> [String] {
        NSString(string: path).pathComponents.filter { component in
            component != "/" && component != "."
        }
    }
}
