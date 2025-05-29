//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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

public struct File: Sendable {
    public enum Error: Swift.Error, CustomStringConvertible {
        case errno(_ e: Int32)

        public var description: String {
            switch self {
            case .errno(let code):
                return "errno \(code)"
            }
        }
    }
    public static func info(_ url: URL) throws -> FileInfo {
        try info(url.path)
    }

    public static func info(_ path: String) throws -> FileInfo {
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw Error.errno(errno)
        }
        return FileInfo(path, stat: st)
    }
}

public struct FileInfo: Sendable {
    private let _stat_t: Foundation.stat
    private let _path: String

    init(_ path: String, stat: stat) {
        self._path = path
        self._stat_t = stat
    }

    public var mode: mode_t {
        self._stat_t.st_mode
    }

    public var uid: Int {
        Int(self._stat_t.st_uid)
    }

    public var gid: Int {
        Int(self._stat_t.st_gid)
    }

    public var dev: Int {
        Int(self._stat_t.st_dev)
    }

    public var ino: Int {
        Int(self._stat_t.st_ino)
    }

    public var size: Int {
        Int(self._stat_t.st_size)
    }

    public var path: String {
        self._path
    }

    public var isDirectory: Bool {
        mode & S_IFMT == S_IFDIR
    }

    public var isPipe: Bool {
        mode & S_IFMT == S_IFIFO
    }

    public var isSocket: Bool {
        mode & S_IFMT == S_IFSOCK
    }

    public var isLink: Bool {
        mode & S_IFMT == S_IFLNK
    }

    public var isRegularFile: Bool {
        mode & S_IFMT == S_IFREG
    }

    public var isBlock: Bool {
        mode & S_IFMT == S_IFBLK
    }

    public var isChar: Bool {
        mode & S_IFMT == S_IFCHR
    }
}
