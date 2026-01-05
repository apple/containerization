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

extension UInt64 {
    public var lo: UInt32 {
        UInt32(self & 0xffff_ffff)
    }

    public var hi: UInt32 {
        UInt32(self >> 32)
    }

    public static func - (lhs: Self, rhs: UInt32) -> UInt64 {
        lhs - UInt64(rhs)
    }

    public static func % (lhs: Self, rhs: UInt32) -> UInt64 {
        lhs % UInt64(rhs)
    }

    public static func / (lhs: Self, rhs: UInt32) -> UInt32 {
        (lhs / UInt64(rhs)).lo
    }

    public static func * (lhs: Self, rhs: UInt32) -> UInt64 {
        lhs * UInt64(rhs)
    }

    public static func * (lhs: Self, rhs: Int) -> UInt64 {
        lhs * UInt64(rhs)
    }
}

extension UInt32 {
    public var lo: UInt16 {
        UInt16(self & 0xffff)
    }

    public var hi: UInt16 {
        UInt16(self >> 16)
    }

    public static func + (lhs: Self, rhs: Int.IntegerLiteralType) -> UInt32 {
        lhs + UInt32(rhs)
    }

    public static func - (lhs: Self, rhs: Int.IntegerLiteralType) -> UInt32 {
        lhs - UInt32(rhs)
    }

    public static func / (lhs: Self, rhs: Int.IntegerLiteralType) -> UInt32 {
        lhs / UInt32(rhs)
    }

    public static func - (lhs: Self, rhs: UInt16) -> UInt32 {
        lhs - UInt32(rhs)
    }

    public static func * (lhs: Self, rhs: Int.IntegerLiteralType) -> Int {
        Int(lhs) * rhs
    }
}

extension Int {
    public static func + (lhs: Self, rhs: UInt32) -> Int {
        lhs + Int(rhs)
    }

    public static func + (lhs: Self, rhs: UInt32) -> UInt32 {
        UInt32(lhs) + rhs
    }
}

extension UInt16 {
    func isDir() -> Bool {
        self & EXT4.FileModeFlag.TypeMask.rawValue == EXT4.FileModeFlag.S_IFDIR.rawValue
    }

    func isLink() -> Bool {
        self & EXT4.FileModeFlag.TypeMask.rawValue == EXT4.FileModeFlag.S_IFLNK.rawValue
    }

    func isReg() -> Bool {
        self & EXT4.FileModeFlag.TypeMask.rawValue == EXT4.FileModeFlag.S_IFREG.rawValue
    }

    func fileType() -> UInt8 {
        typealias FMode = EXT4.FileModeFlag
        typealias FileType = EXT4.FileType
        switch self & FMode.TypeMask.rawValue {
        case FMode.S_IFREG.rawValue:
            return FileType.regular.rawValue
        case FMode.S_IFDIR.rawValue:
            return FileType.directory.rawValue
        case FMode.S_IFCHR.rawValue:
            return FileType.character.rawValue
        case FMode.S_IFBLK.rawValue:
            return FileType.block.rawValue
        case FMode.S_IFIFO.rawValue:
            return FileType.fifo.rawValue
        case FMode.S_IFSOCK.rawValue:
            return FileType.socket.rawValue
        case FMode.S_IFLNK.rawValue:
            return FileType.symbolicLink.rawValue
        default:
            return FileType.unknown.rawValue
        }
    }
}

extension [UInt8] {
    var allZeros: Bool {
        for num in self where num != 0 {
            return false
        }
        return true
    }
}
