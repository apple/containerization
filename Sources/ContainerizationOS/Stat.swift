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

/// A timestamp with second and nanosecond precision.
public struct TimeSpec: Sendable, Hashable {
    /// Seconds since the Unix epoch.
    public var seconds: Int64
    /// Nanoseconds past the second.
    public var nanoseconds: Int32

    public init(seconds: Int64, nanoseconds: Int32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
}

/// File metadata returned by a `stat` call.
public struct Stat: Sendable, Hashable {
    /// ID of device containing file (`st_dev`).
    public var dev: UInt64
    /// Inode number (`st_ino`).
    public var ino: UInt64
    /// File type and mode (`st_mode`).
    public var mode: UInt32
    /// Number of hard links (`st_nlink`).
    public var nlink: UInt64
    /// User ID of owner (`st_uid`).
    public var uid: UInt32
    /// Group ID of owner (`st_gid`).
    public var gid: UInt32
    /// Device ID, if special file (`st_rdev`).
    public var rdev: UInt64
    /// Total size in bytes (`st_size`).
    public var size: Int64
    /// Preferred I/O block size (`st_blksize`).
    public var blksize: Int64
    /// Number of 512-byte blocks allocated (`st_blocks`).
    public var blocks: Int64
    /// Time of last access (`st_atim`).
    public var atime: TimeSpec
    /// Time of last modification (`st_mtim`).
    public var mtime: TimeSpec
    /// Time of last status change (`st_ctim`).
    public var ctime: TimeSpec

    public init(
        dev: UInt64,
        ino: UInt64,
        mode: UInt32,
        nlink: UInt64,
        uid: UInt32,
        gid: UInt32,
        rdev: UInt64,
        size: Int64,
        blksize: Int64,
        blocks: Int64,
        atime: TimeSpec,
        mtime: TimeSpec,
        ctime: TimeSpec
    ) {
        self.dev = dev
        self.ino = ino
        self.mode = mode
        self.nlink = nlink
        self.uid = uid
        self.gid = gid
        self.rdev = rdev
        self.size = size
        self.blksize = blksize
        self.blocks = blocks
        self.atime = atime
        self.mtime = mtime
        self.ctime = ctime
    }
}
