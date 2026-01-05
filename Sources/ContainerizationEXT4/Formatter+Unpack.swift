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

#if os(macOS)
import ContainerizationArchive
import Foundation
import ContainerizationOS
import SystemPackage
import ContainerizationExtras

private typealias Hardlinks = [FilePath: FilePath]

extension EXT4.Formatter {
    /// Unpack the provided archive on to the ext4 filesystem.
    public func unpack(reader: ArchiveReader, progress: ProgressHandler? = nil) throws {
        var hardlinks: Hardlinks = [:]
        // Allocate a single 128KiB reusable buffer for all files to minimize allocations
        // and reduce the number of read calls to libarchive.
        let bufferSize = 128 * 1024
        let reusableBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
        defer { reusableBuffer.deallocate() }

        for (entry, streamReader) in reader.makeStreamingIterator() {
            try Task.checkCancellation()
            guard var pathEntry = entry.path else {
                continue
            }

            defer {
                // Count the number of entries
                if let progress {
                    Task {
                        await progress([
                            ProgressEvent(event: "add-items", value: 1)
                        ])
                    }
                }
            }

            pathEntry = preProcessPath(s: pathEntry)
            let path = FilePath(pathEntry)

            if path.base.hasPrefix(".wh.") {
                if path.base == ".wh..wh..opq" {  // whiteout directory
                    try self.unlink(path: path.dir, directoryWhiteout: true)
                    continue
                }
                let startIndex = path.base.index(path.base.startIndex, offsetBy: ".wh.".count)
                let filePath = String(path.base[startIndex...])
                let dir: FilePath = path.dir
                try self.unlink(path: dir.join(filePath))
                continue
            }

            if let hardlink = entry.hardlink {
                let hl = preProcessPath(s: hardlink)
                hardlinks[path] = FilePath(hl)
                continue
            }
            let ts = FileTimestamps(
                access: entry.contentAccessDate, modification: entry.modificationDate, creation: entry.creationDate)
            switch entry.fileType {
            case .directory:
                try self.create(
                    path: path, mode: EXT4.Inode.Mode(.S_IFDIR, entry.permissions), ts: ts, uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs)
            case .regular:
                try self.create(
                    path: path, mode: EXT4.Inode.Mode(.S_IFREG, entry.permissions), ts: ts, buf: streamReader,
                    uid: entry.owner,
                    gid: entry.group, xattrs: entry.xattrs, fileBuffer: reusableBuffer)

                // Count the size of files
                if let progress, let size = entry.size {
                    Task {
                        await progress([
                            ProgressEvent(event: "add-size", value: Int64(size))
                        ])
                    }
                }
            case .symbolicLink:
                var symlinkTarget: FilePath?
                if let target = entry.symlinkTarget {
                    symlinkTarget = FilePath(target)
                }
                try self.create(
                    path: path, link: symlinkTarget, mode: EXT4.Inode.Mode(.S_IFLNK, entry.permissions), ts: ts,
                    uid: entry.owner,
                    gid: entry.group, xattrs: entry.xattrs)
            default:
                continue
            }
        }
        guard hardlinks.acyclic else {
            throw UnpackError.circularLinks
        }
        for (path, _) in hardlinks {
            if let resolvedTarget = try hardlinks.resolve(path) {
                try self.link(link: path, target: resolvedTarget)
            }
        }
    }

    /// Unpack an archive at the source URL on to the ext4 filesystem.
    public func unpack(
        source: URL,
        format: ContainerizationArchive.Format = .paxRestricted,
        compression: ContainerizationArchive.Filter = .gzip,
        progress: ProgressHandler? = nil
    ) throws {
        let reader = try ArchiveReader(
            format: format,
            filter: compression,
            file: source
        )
        try self.unpack(reader: reader, progress: progress)
    }

    private func preProcessPath(s: String) -> String {
        var p = s
        if p.hasPrefix("./") {
            p = String(p.dropFirst())
        }
        if !p.hasPrefix("/") {
            p = "/" + p
        }
        return p
    }
}

/// Common errors for unpacking an archive onto an ext4 filesystem.
public enum UnpackError: Swift.Error, CustomStringConvertible, Sendable, Equatable {
    /// The name is invalid.
    case invalidName(_ name: String)
    /// A circular link is found.
    case circularLinks

    /// The description of the error.
    public var description: String {
        switch self {
        case .invalidName(let name):
            return "'\(name)' is an invalid name"
        case .circularLinks:
            return "circular links found"
        }
    }
}

extension Hardlinks {
    fileprivate var acyclic: Bool {
        for (_, target) in self {
            var visited: Set<FilePath> = [target]
            var next = target
            while let item = self[next] {
                if visited.contains(item) {
                    return false
                }
                next = item
                visited.insert(next)
            }
        }
        return true
    }

    fileprivate func resolve(_ key: FilePath) throws -> FilePath? {
        let target = self[key]
        guard let target else {
            return nil
        }
        var next = target
        let visited: Set<FilePath> = [next]
        while let item = self[next] {
            if visited.contains(item) {
                throw UnpackError.circularLinks
            }
            next = item
        }
        return next
    }
}
#endif
