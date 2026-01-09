//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
import SystemPackage
import Testing

@testable import ContainerizationEXT4

struct TestEXT4Reader {
    @Test func testEXT4ReaderInitWithNonExistentFile() {
        let nonExistentPath = FilePath("/non/existent/path.ext4")

        #expect(throws: EXT4.Error.self) {
            try EXT4.EXT4Reader(blockDevice: nonExistentPath)
        }
    }

    @Test func testEXT4ReaderBlockSize() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        let blockSize = reader.blockSize

        #expect(blockSize == UInt64(1024 * (1 << reader.superBlock.logBlockSize)))
    }

    @Test func testEXT4ReaderSuperBlockAccess() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        let superBlock = reader.superBlock

        #expect(superBlock.magic == EXT4.SuperBlockMagic)
        #expect(superBlock.logBlockSize >= 0)
        #expect(superBlock.blocksCountLow > 0)
    }

    @Test func testEXT4ReaderGetGroupDescriptor() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        let groupDescriptor = try reader.getGroupDescriptor(0)

        #expect(groupDescriptor.blockBitmapLow > 0)
        #expect(groupDescriptor.inodeBitmapLow > 0)
        #expect(groupDescriptor.inodeTableLow > 0)
    }

    @Test func testEXT4ReaderGetInode() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        try formatter.create(path: FilePath("/test_file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: nil)
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        let rootInode = try reader.getInode(number: EXT4.RootInode)

        #expect(rootInode.mode.isDir())
        #expect(rootInode.linksCount > 0)
    }

    @Test func testEXT4ReaderChildren() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        try formatter.create(path: FilePath("/test_dir"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.create(path: FilePath("/test_file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: nil)
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        let children = try reader.children(of: EXT4.RootInode)

        let childNames = children.map { $0.0 }
        #expect(childNames.contains("test_dir"))
        #expect(childNames.contains("test_file"))
        #expect(childNames.contains("lost+found"))
    }

    @Test func testEXT4ReaderInvalidInodeNumber() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)

        // Test with an inode number that's beyond the filesystem's capacity
        let maxInodeNumber = reader.superBlock.inodesCount
        let invalidInodeNumber = maxInodeNumber + 1000

        let inode = try reader.getInode(number: invalidInodeNumber)

        // The inode should be empty/unallocated (all zeros)
        #expect(inode.mode == 0)
        #expect(inode.linksCount == 0)
        #expect(inode.sizeLow == 0)
    }
}
