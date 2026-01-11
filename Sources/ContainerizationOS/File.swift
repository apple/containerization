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

import Foundation

/// Trivial type to discover information about a given file (uid, gid, mode...).
public struct File: Sendable {
    /// `File` errors.
    public enum Error: Swift.Error, CustomStringConvertible {
        case errno(_ e: Int32)

        public var description: String {
            switch self {
            case .errno(let code):
                return "errno \(code)"
            }
        }
    }

    /// Returns a `FileInfo` struct with information about the file.
    /// - Parameters:
    ///   - url: The path to the file.
    public static func info(_ url: URL) throws -> FileInfo {
        try info(url.path)
    }

    /// Returns a `FileInfo` struct with information about the file.
    /// - Parameters:
    ///   - path: The path to the file as a string.
    public static func info(_ path: String) throws -> FileInfo {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw Error.errno(errno)
        }
        return FileInfo(path, stat: st)
    }
}

/// `FileInfo` holds and provides easy access to stat(2) data
/// for a file.
public struct FileInfo: Sendable {
    private let _stat_t: Foundation.stat
    private let _path: String

    init(_ path: String, stat: stat) {
        self._path = path
        self._stat_t = stat
    }

    /// mode_t for the file.
    public var mode: mode_t {
        self._stat_t.st_mode
    }

    /// The files uid.
    public var uid: Int {
        Int(self._stat_t.st_uid)
    }

    /// The files gid.
    public var gid: Int {
        Int(self._stat_t.st_gid)
    }

    /// The filesystem ID the file belongs to.
    public var dev: Int {
        Int(self._stat_t.st_dev)
    }

    /// The files inode number.
    public var ino: Int {
        Int(self._stat_t.st_ino)
    }

    /// The size of the file.
    public var size: Int {
        Int(self._stat_t.st_size)
    }

    /// The path to the file.
    public var path: String {
        self._path
    }

    /// Returns if the file is a directory.
    public var isDirectory: Bool {
        mode & S_IFMT == S_IFDIR
    }

    /// Returns if the file is a pipe.
    public var isPipe: Bool {
        mode & S_IFMT == S_IFIFO
    }

    /// Returns if the file is a socket.
    public var isSocket: Bool {
        mode & S_IFMT == S_IFSOCK
    }

    /// Returns if the file is a link.
    public var isLink: Bool {
        mode & S_IFMT == S_IFLNK
    }

    /// Returns if the file is a regular file.
    public var isRegularFile: Bool {
        mode & S_IFMT == S_IFREG
    }

    /// Returns if the file is a block device.
    public var isBlock: Bool {
        mode & S_IFMT == S_IFBLK
    }

    /// Returns if the file is a character device.
    public var isChar: Bool {
        mode & S_IFMT == S_IFCHR
    }
}
