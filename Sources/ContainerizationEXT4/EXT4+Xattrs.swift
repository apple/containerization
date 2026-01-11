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

/*
 * Note: Both the entries and values for the attributes need to occupy a size that is a multiple of 4,
 * meaning, in cases where the attribute name or value is less than not a multiple of 4, it is padded with 0
 * until it reaches that size.
 */

extension EXT4 {
    public struct ExtendedAttribute {
        public static let prefixMap: [Int: String] = [
            1: "user.",
            2: "system.posix_acl_access",
            3: "system.posix_acl_default",
            4: "trusted.",
            6: "security.",
            7: "system.",
            8: "system.richacl",
        ]

        let name: String
        let index: UInt8
        let value: [UInt8]

        var sizeValue: UInt32 {
            UInt32((value.count + 3) & ~3)
        }

        var sizeEntry: UInt32 {
            UInt32((name.count + 3) & ~3 + 16)  // 16 bytes are needed to store other metadata for the xattr entry
        }

        var size: UInt32 {
            sizeEntry + sizeValue
        }

        var fullName: String {
            Self.decompressName(id: Int(index), suffix: name)
        }

        var hash: UInt32 {
            var hash: UInt32 = 0
            for char in name {
                hash = (hash << 5) ^ (hash >> 27) ^ UInt32(char.asciiValue!)
            }
            var i = 0
            while i + 3 < value.count {
                let s = value[i..<i + 4]
                let v = UInt32(littleEndian: s.withUnsafeBytes { $0.load(as: UInt32.self) })
                hash = (hash << 16) ^ (hash >> 16) ^ v
                i += 4
            }
            if value.count % 4 != 0 {
                let last = value.count & ~3
                var buff: [UInt8] = [0, 0, 0, 0]
                for (i, byte) in value[last...].enumerated() {
                    buff[i] = byte
                }
                let v = UInt32(littleEndian: buff.withUnsafeBytes { $0.load(as: UInt32.self) })
                hash = (hash << 16) ^ (hash >> 16) ^ v
            }
            return hash
        }

        init(name: String, value: [UInt8]) {
            let compressed = Self.compressName(name)
            self.name = compressed.str
            self.index = compressed.id
            self.value = value
        }

        init(idx: UInt8, compressedName name: String, value: [UInt8]) {
            self.name = name
            self.index = idx
            self.value = value
        }

        // MARK: Class methods
        public static func compressName(_ name: String) -> (id: UInt8, str: String) {
            for (id, prefix) in prefixMap.sorted(by: { $1.1.count < $0.1.count }) where name.hasPrefix(prefix) {
                return (UInt8(id), String(name.dropFirst(prefix.count)))
            }
            return (0, name)
        }

        public static func decompressName(id: Int, suffix: String) -> String {
            guard let prefix = prefixMap[id] else {
                return suffix
            }
            return "\(prefix)\(suffix)"
        }
    }

    public struct FileXattrsState {
        private let inodeCapacity: UInt32
        private let blockCapacity: UInt32
        private let inode: UInt32  // the inode number for which we are tracking these xattrs

        var inlineAttributes: [ExtendedAttribute] = []
        var blockAttributes: [ExtendedAttribute] = []
        private var usedSizeInline: UInt32 = 0
        private var usedSizeBlock: UInt32 = 0

        private var inodeFreeBytes: UInt32 {
            self.inodeCapacity - EXT4.XattrInodeHeaderSize - usedSizeInline - 4  // need to have 4 null bytes b/w xattr entries and values
        }

        private var blockFreeBytes: UInt32 {
            self.blockCapacity - EXT4.XattrBlockHeaderSize - usedSizeBlock - 4
        }

        init(inode: UInt32, inodeXattrCapacity: UInt32, blockCapacity: UInt32) {
            self.inode = inode
            self.inodeCapacity = inodeXattrCapacity
            self.blockCapacity = blockCapacity
        }

        public mutating func add(_ attribute: ExtendedAttribute) throws {
            let size = attribute.size
            if size <= inodeFreeBytes {
                usedSizeInline += size
                inlineAttributes.append(attribute)
                return
            }
            if size <= blockFreeBytes {
                usedSizeBlock += size
                blockAttributes.append(attribute)
                return
            }
            throw Error.insufficientSpace(Int(self.inode))
        }

        public func writeInlineAttributes(buffer: inout [UInt8]) throws {
            var idx = 0
            withUnsafeLittleEndianBytes(
                of: EXT4.XAttrHeaderMagic,
                body: { bytes in
                    for byte in bytes {
                        buffer[idx] = byte
                        idx += 1
                    }
                })
            try Self.write(buffer: &buffer, attrs: self.inlineAttributes, start: UInt16(idx), delta: 0, inline: true)
        }

        public func writeBlockAttributes(buffer: inout [UInt8]) throws {
            var idx = 0
            for val in [EXT4.XAttrHeaderMagic, 1, 1] {
                withUnsafeLittleEndianBytes(
                    of: UInt32(val),
                    body: { bytes in
                        for byte in bytes {
                            buffer[idx] = byte
                            idx += 1
                        }
                    })
            }
            while idx != 32 {
                buffer[idx] = 0
                idx += 1
            }
            var attributes = self.blockAttributes
            attributes.sort(by: {
                if ($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name) {
                    return true
                }
                return false
            })
            try Self.write(buffer: &buffer, attrs: attributes, start: UInt16(idx), delta: UInt16(idx), inline: false)
        }

        /// Writes the specified list of extended attribute entries and their values to the provided
        /// This method does not fill in any headers (Inode inline / block level) that may be required to parse these attributes
        ///
        /// - Parameters:
        ///   - buffer: An array of [UInt8] where the data will be written into
        ///   - attrs: The list of ExtendedAttributes to write
        ///   - start: the index from where data should be put into the buffer - useful when if you dont want this method to be overwriting existing data
        ///   - delta: index from where the begin the offset calculations
        ///   - inline: if the byte buffer being written into is an inline data block for an inode: Determines the hash calculation
        private static func write(
            buffer: inout [UInt8], attrs: [ExtendedAttribute], start: UInt16, delta: UInt16, inline: Bool
        ) throws {
            var offset: UInt16 = UInt16(buffer.count) + delta - start
            var front = Int(start)
            var end = buffer.count

            for attribute in attrs {
                guard end - front >= 4 else {
                    throw Error.malformedXattrBuffer
                }

                var out: [UInt8] = []
                let v = attribute.sizeValue
                offset -= UInt16(v)
                out.append(UInt8(attribute.name.count))
                out.append(attribute.index)
                withUnsafeLittleEndianBytes(
                    of: UInt16(offset),
                    body: { bytes in
                        out.append(contentsOf: bytes)
                    })
                out.append(contentsOf: [0, 0, 0, 0])  // these next four bytes indicate that the attr values are in the same block
                withUnsafeLittleEndianBytes(
                    of: UInt32(attribute.value.count),
                    body: { bytes in
                        out.append(contentsOf: bytes)
                    })
                if !inline {
                    withUnsafeLittleEndianBytes(
                        of: UInt32(attribute.hash),
                        body: { bytes in
                            out.append(contentsOf: bytes)
                        })
                } else {
                    out.append(contentsOf: [0, 0, 0, 0])
                }
                guard let name = attribute.name.data(using: .ascii) else {
                    throw Error.convertAsciiString(attribute.name)
                }
                out.append(contentsOf: [UInt8](name))
                while out.count < Int(attribute.sizeEntry) {  // ensure that xattr entry size is a multiple of 4
                    out.append(0)
                }
                for (i, byte) in out.enumerated() {
                    buffer[front + i] = byte
                }
                front += out.count

                end -= Int(attribute.sizeValue)
                for (i, byte) in attribute.value.enumerated() {
                    buffer[end + i] = byte
                }
            }
        }

        public static func read(buffer: [UInt8], start: Int, offset: Int) throws -> [ExtendedAttribute] {
            var i = start
            var attribs: [ExtendedAttribute] = []
            // 16 is the size of 1 XAttrEntry
            while i + 16 < buffer.count {
                let attributeStart = i
                let rawXattrEntry = Array(buffer[i..<i + 16])
                let xattrEntry = try EXT4.XAttrEntry(using: rawXattrEntry)
                i += 16
                var endIndex = i + Int(xattrEntry.nameLength)
                guard endIndex < buffer.count else {
                    continue
                }
                let rawName = buffer[i..<endIndex]
                let name = String(bytes: rawName, encoding: .ascii)!
                let valueStart = Int(xattrEntry.valueOffset) + offset
                let valueEnd = Int(xattrEntry.valueOffset) + Int(xattrEntry.valueSize) + offset
                let value = [UInt8](buffer[valueStart..<valueEnd])
                let xattr = ExtendedAttribute(idx: xattrEntry.nameIndex, compressedName: name, value: value)
                attribs.append(xattr)
                i = attributeStart + xattr.sizeEntry
                // The next 4 bytes being null indicate that there are no more attributes to read
                endIndex = i + 3
                guard endIndex < buffer.count else {
                    continue
                }
                if Array(buffer[i...i + 3]) == [0, 0, 0, 0] {
                    break
                }
            }
            return attribs
        }

        public enum Error: CustomStringConvertible, Swift.Error {
            case insufficientSpace(_ inode: Int)
            case malformedXattrBuffer
            case convertAsciiString(_ s: String)
            case missingXAttrHeader

            public var description: String {
                switch self {
                case .insufficientSpace(let inode):
                    return "cannot fit xattr for inode \(inode)"
                case .malformedXattrBuffer:
                    return "malformed extended attribute buffer"
                case .convertAsciiString(let s):
                    return "cannot convert string \(s) to a list of ASCII characters"
                case .missingXAttrHeader:
                    return "missing header for extended attribute entry"
                }
            }
        }
    }
}
