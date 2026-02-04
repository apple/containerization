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

extension EXT4.InodeFlag {
    public static func | (lhs: Self, rhs: Self) -> Self {
        Self(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt32 {
        lhs.rawValue | rhs.rawValue
    }

    public static func | (lhs: Self, rhs: UInt32) -> UInt32 {
        lhs.rawValue | rhs
    }
}

extension EXT4.CompatFeature {
    public static func | (lhs: Self, rhs: Self) -> Self {
        EXT4.CompatFeature(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt32 {
        lhs.rawValue | rhs.rawValue
    }
}

extension EXT4.IncompatFeature {
    public static func | (lhs: Self, rhs: Self) -> Self {
        EXT4.IncompatFeature(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt32 {
        lhs.rawValue | rhs.rawValue
    }
}

extension EXT4.RoCompatFeature {
    public static func | (lhs: Self, rhs: Self) -> Self {
        EXT4.RoCompatFeature(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt32 {
        lhs.rawValue | rhs.rawValue
    }
}

extension EXT4.FileModeFlag {
    public static func | (lhs: Self, rhs: Self) -> Self {
        Self(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt16 {
        lhs.rawValue | rhs.rawValue
    }
}

extension EXT4.XAttrEntry {
    init(using bytes: [UInt8]) throws {
        guard bytes.count == 16 else {
            throw EXT4.Error.invalidXattrEntry
        }
        nameLength = bytes[0]
        nameIndex = bytes[1]
        let rawValue = Array(bytes[2...3])
        valueOffset = UInt16(littleEndian: rawValue.withUnsafeBytes { $0.load(as: UInt16.self) })

        let rawValueInum = Array(bytes[4...7])
        valueInum = UInt32(littleEndian: rawValueInum.withUnsafeBytes { $0.load(as: UInt32.self) })

        let rawSize = Array(bytes[8...11])
        valueSize = UInt32(littleEndian: rawSize.withUnsafeBytes { $0.load(as: UInt32.self) })

        let rawHash = Array(bytes[12...])
        hash = UInt32(littleEndian: rawHash.withUnsafeBytes { $0.load(as: UInt32.self) })
    }
}

extension EXT4 {
    static func tupleToArray<T>(_ tuple: T) -> [UInt8] {
        let reflection = Mirror(reflecting: tuple)
        return reflection.children.compactMap { $0.value as? UInt8 }
    }
}
