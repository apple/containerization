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
import SystemPackage

extension EXT4.EXT4Reader {
    public func export(archive: FilePath) throws {
        let config = ArchiveWriterConfiguration(
            format: .paxRestricted, filter: .none, options: [Options.xattrformat(.schily)])
        let writer = try ArchiveWriter(configuration: config)
        try writer.open(file: archive.url)
        var items = self.tree.root.pointee.children
        let hardlinkedInodes = Set(self.hardlinks.values)
        var hardlinkTargets: [EXT4.InodeNumber: FilePath] = [:]

        while items.count > 0 {
            let itemPtr = items.removeFirst()
            let item = itemPtr.pointee
            let inode = try self.getInode(number: item.inode)
            let entry = WriteEntry()
            let mode = inode.mode
            let size: UInt64 = (UInt64(inode.sizeHigh) << 32) | UInt64(inode.sizeLow)
            entry.permissions = mode
            guard let path = item.path else {
                continue
            }
            if hardlinkedInodes.contains(item.inode) {
                hardlinkTargets[item.inode] = path
            }
            guard self.hardlinks[path] == nil else {
                continue
            }
            var attributes: [EXT4.ExtendedAttribute] = []
            let buffer: [UInt8] = EXT4.tupleToArray(inode.inlineXattrs)
            if !buffer.allZeros {
                try attributes.append(contentsOf: Self.readInlineExtendedAttributes(from: buffer))
            }
            if inode.xattrBlockLow != 0 {
                let block = inode.xattrBlockLow
                try self.seek(block: block)
                guard let buffer = try self.handle.read(upToCount: Int(self.blockSize)) else {
                    throw EXT4.Error.couldNotReadBlock(block)
                }
                try attributes.append(contentsOf: Self.readBlockExtendedAttributes(from: [UInt8](buffer)))
            }

            var xattrs: [String: Data] = [:]
            for attribute in attributes {
                guard attribute.fullName != "system.data" else {
                    continue
                }
                xattrs[attribute.fullName] = Data(attribute.value)
            }

            let pathStr = path.description
            entry.path = pathStr
            entry.size = Int64(size)
            entry.group = gid_t(inode.gid)
            entry.owner = uid_t(inode.uid)
            entry.creationDate = Date(fsTimestamp: UInt64((inode.ctimeExtra << 32) | inode.ctime))
            entry.modificationDate = Date(fsTimestamp: UInt64((inode.mtimeExtra << 32) | inode.mtime))
            entry.contentAccessDate = Date(fsTimestamp: UInt64((inode.atimeExtra << 32) | inode.atime))
            entry.xattrs = xattrs

            if mode.isDir() {
                entry.fileType = .directory
                for child in item.children {
                    items.append(child)
                }
                if pathStr == "" {
                    continue
                }
                try writer.writeEntry(entry: entry, data: nil)
            } else if mode.isReg() {
                entry.fileType = .regular
                var data = Data()
                var remaining: UInt64 = size
                if let block = item.blocks {
                    for dataBlock in block.start..<block.end {
                        try self.seek(block: dataBlock)
                        var count: UInt64
                        if remaining > self.blockSize {
                            count = self.blockSize
                        } else {
                            count = remaining
                        }
                        guard let dataBytes = try self.handle.read(upToCount: Int(count)) else {
                            throw EXT4.Error.couldNotReadBlock(dataBlock)
                        }
                        data.append(dataBytes)
                        remaining -= UInt64(dataBytes.count)
                    }
                }
                if let additionalBlocks = item.additionalBlocks {
                    for block in additionalBlocks {
                        for dataBlock in block.start..<block.end {
                            try self.seek(block: dataBlock)
                            var count: UInt64
                            if remaining > self.blockSize {
                                count = self.blockSize
                            } else {
                                count = remaining
                            }
                            guard let dataBytes = try self.handle.read(upToCount: Int(count)) else {
                                throw EXT4.Error.couldNotReadBlock(dataBlock)
                            }
                            data.append(dataBytes)
                            remaining -= UInt64(dataBytes.count)
                        }
                    }
                }
                try writer.writeEntry(entry: entry, data: data)
            } else if mode.isLink() {
                entry.fileType = .symbolicLink
                if size < 60 {
                    let linkBytes = EXT4.tupleToArray(inode.block)
                    entry.symlinkTarget = String(bytes: linkBytes, encoding: .utf8) ?? ""
                } else {
                    if let block = item.blocks {
                        try self.seek(block: block.start)
                        guard let linkBytes = try self.handle.read(upToCount: Int(size)) else {
                            throw EXT4.Error.couldNotReadBlock(block.start)
                        }
                        entry.symlinkTarget = String(bytes: linkBytes, encoding: .utf8) ?? ""
                    }
                }
                try writer.writeEntry(entry: entry, data: nil)
            } else {  // do not process sockets, fifo, character and block devices
                continue
            }
        }
        for (path, number) in self.hardlinks {
            guard let targetPath = hardlinkTargets[number] else {
                continue
            }
            let inode = try self.getInode(number: number)
            let entry = WriteEntry()
            entry.path = path.description
            entry.hardlink = targetPath.description
            entry.permissions = inode.mode
            entry.group = gid_t(inode.gid)
            entry.owner = uid_t(inode.uid)
            entry.creationDate = Date(fsTimestamp: UInt64((inode.ctimeExtra << 32) | inode.ctime))
            entry.modificationDate = Date(fsTimestamp: UInt64((inode.mtimeExtra << 32) | inode.mtime))
            entry.contentAccessDate = Date(fsTimestamp: UInt64((inode.atimeExtra << 32) | inode.atime))
            try writer.writeEntry(entry: entry, data: nil)
        }
        try writer.finishEncoding()
    }

    @available(*, deprecated, renamed: "readInlineExtendedAttributes(from:)")
    public static func readInlineExtenedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        try readInlineExtendedAttributes(from: buffer)
    }

    public static func readInlineExtendedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        let header = UInt32(littleEndian: buffer[0...4].withUnsafeBytes { $0.load(as: UInt32.self) })
        if header != EXT4.XAttrHeaderMagic {
            throw EXT4.FileXattrsState.Error.missingXAttrHeader
        }
        return try EXT4.FileXattrsState.read(buffer: buffer, start: 4, offset: 4)
    }

    @available(*, deprecated, renamed: "readBlockExtendedAttributes(from:)")
    public static func readBlockExtenedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        try readBlockExtendedAttributes(from: buffer)
    }

    public static func readBlockExtendedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        let header = UInt32(littleEndian: buffer[0...4].withUnsafeBytes { $0.load(as: UInt32.self) })
        if header != EXT4.XAttrHeaderMagic {
            throw EXT4.FileXattrsState.Error.missingXAttrHeader
        }

        return try EXT4.FileXattrsState.read(buffer: [UInt8](buffer), start: 32, offset: 0)
    }

    func seek(block: UInt32) throws {
        try self.handle.seek(toOffset: UInt64(block) * blockSize)
    }
}

extension Date {
    init(fsTimestamp: UInt64) {
        if fsTimestamp == 0 {
            self = Date.distantPast
            return
        }

        let seconds = Int64(fsTimestamp & 0x3_ffff_ffff)
        let nanoseconds = Double(fsTimestamp >> 34) / 1_000_000_000

        self = Date(timeIntervalSince1970: Double(seconds) + nanoseconds)
    }
}
#endif
