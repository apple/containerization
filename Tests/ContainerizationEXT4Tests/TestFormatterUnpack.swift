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

// swiftlint:disable force_try static_over_final_class

#if os(macOS)
import ContainerizationArchive
import Foundation
import Testing
import SystemPackage

@testable import ContainerizationEXT4

struct Tar2EXT4Test: ~Copyable {
    let fsPath = FilePath(
        FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("ext4.tar.img.delme", isDirectory: false))

    let xattrs: [String: Data] = [
        "foo.bar": Data([1, 2, 3]),
        "bar": Data([0, 0, 0]),
        "system.richacl.bar": Data([99, 1, 9, 1]),
        "foobar.user": Data([71, 2, 45]),
        "test.xattr.cap": Data([1, 32, 3]),
        "testing123": Data([12, 24, 45]),
        "sys.admin": Data([16, 23, 13]),
        "test.123": Data([15, 26, 54]),
        "extendedattribute.test": Data([15, 26, 54, 1, 2, 4, 6, 7, 7]),
    ]

    init() throws {
        // create layer1
        let layer1Path = FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("layer1.tar.gz", isDirectory: false)
        let layer1Archiver = try ArchiveWriter(
            configuration: ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip))
        try layer1Archiver.open(file: layer1Path)
        // create 2 directories and fill them with files
        try layer1Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir1", permissions: 0o755), data: nil)
        try layer1Archiver.writeEntry(entry: WriteEntry.file(path: "/dir1/file1", permissions: 0o644), data: nil)
        try layer1Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir2", permissions: 0o755), data: nil)
        try layer1Archiver.writeEntry(entry: WriteEntry.file(path: "/dir2/file1", permissions: 0o644), data: nil)
        try layer1Archiver.finishEncoding()

        // create layer2
        let layer2Path = FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("layer2.tar.gz", isDirectory: false)
        let layer2Archiver = try ArchiveWriter(
            configuration: ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip))
        try layer2Archiver.open(file: layer2Path)
        // create 3 directories and fill them with files and whiteouts
        try layer2Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir1", permissions: 0o755), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.file(path: "/dir1/.wh.file1", permissions: 0o644), data: nil)
        try layer2Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir2", permissions: 0o755), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.file(path: "/dir2/.wh..wh..opq", permissions: 0o644), data: nil)
        try layer2Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir3", permissions: 0o755), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.file(path: "/dir3/file1", permissions: 0o644, xattrs: xattrs), data: nil)
        try layer2Archiver.writeEntry(entry: WriteEntry.dir(path: "/dir4", permissions: 0o755), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.file(path: "/dir4/special_ÆÂ©", permissions: 0o644), data: nil)
        try layer2Archiver.writeEntry(
            entry: WriteEntry.link(path: "/dir4/specialcharacters", permissions: 0o644, target: "special_ÆÂ©"),
            data: nil)

        // a new layer overwriting over an existing layer
        try layer2Archiver.writeEntry(entry: WriteEntry.file(path: "/dir2/file1", permissions: 0o644), data: nil)
        try layer2Archiver.finishEncoding()

        let unpacker = try EXT4.Formatter(fsPath)
        try unpacker.unpack(source: layer1Path)
        try unpacker.unpack(source: layer2Path)
        try unpacker.close()
    }

    deinit {
        try? FileManager.default.removeItem(at: fsPath.url)
    }

    @Test func testUnpackBasic() throws {
        let ext4 = try EXT4.EXT4Reader(blockDevice: fsPath)
        // just a directory
        let dir1Inode = try ext4.getInode(number: 12)
        #expect(dir1Inode.mode.isDir())
        // white out file /dir1/file1
        let dir1File1Inode = try ext4.getInode(number: 13)
        #expect(dir1File1Inode.dtime != 0)
        #expect(dir1File1Inode.linksCount == 0)  // deleted
        // white out dir /dir2
        let dir2Inode = try ext4.getInode(number: 14)
        #expect(dir2Inode.dtime == 0)
        #expect(dir2Inode.linksCount == 2)  // children deleted
        // new dir /dir3
        let dir3Inode = try ext4.getInode(number: 16)
        #expect(dir3Inode.mode.isDir())
        #expect(dir3Inode.linksCount == 2)
        // new file /dir3/file1
        let dir3File1Inode = try ext4.getInode(number: 17)
        #expect(dir3File1Inode.mode.isReg())
        #expect(dir3File1Inode.linksCount == 1)
        #expect(try ext4.getXattrsForInode(inode: dir3File1Inode) == xattrs)
        // overwritten dir /dir2
        let dir2OverwriteInode = try ext4.getInode(number: 18)
        #expect(dir2OverwriteInode.mode.isDir())
        #expect(dir2OverwriteInode.linksCount == 2)
        // /dir4/special_ÆÂ©
        let dir2File1OverwriteInode = try ext4.getInode(number: 19)
        #expect(dir2File1OverwriteInode.mode.isReg())
        #expect(dir2File1OverwriteInode.linksCount == 1)

        let specialFileInode = try ext4.getInode(number: 20)
        let bytes = Data(Mirror(reflecting: specialFileInode.block).children.compactMap { $0.value as? UInt8 })
        let specialFileTarget = try #require(FilePath(bytes), "Could not parse special file path")
        #expect(specialFileTarget.description.hasPrefix("special_ÆÂ©"))
    }
}

extension ContainerizationArchive.WriteEntry {
    static func dir(path: String, permissions: UInt16) -> WriteEntry {
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .directory
        entry.permissions = permissions
        return entry
    }

    static func file(path: String, permissions: UInt16, size: Int64? = nil, xattrs: [String: Data]? = nil) -> WriteEntry {
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .regular
        entry.permissions = permissions
        entry.size = size
        if let xattrs {
            entry.xattrs = xattrs
        }
        return entry
    }

    static func link(path: String, permissions: UInt16, target: String) -> WriteEntry {
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .symbolicLink
        entry.symlinkTarget = target
        return entry
    }
}

extension EXT4.EXT4Reader {
    fileprivate func getXattrsForInode(inode: EXT4.Inode) throws -> [String: Data] {
        var attributes: [EXT4.ExtendedAttribute] = []
        let buffer: [UInt8] = EXT4.tupleToArray(inode.inlineXattrs)
        try attributes.append(contentsOf: Self.readInlineExtendedAttributes(from: buffer))
        let block = inode.xattrBlockLow
        try self.seek(block: block)
        let buf = try self.handle.read(upToCount: Int(self.blockSize))!
        try attributes.append(contentsOf: Self.readBlockExtendedAttributes(from: [UInt8](buf)))
        var xattrs: [String: Data] = [:]
        for attribute in attributes {
            guard attribute.fullName != "system.data" else {
                continue
            }
            xattrs[attribute.fullName] = Data(attribute.value)
        }
        return xattrs
    }
}
#endif
