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

import Foundation
import SystemPackage
import Testing

@testable import ContainerizationEXT4

struct Ext4FormatLinkTests {
    @Test func hardlinkLinksCount() throws {
        func makeFile(unlink: Bool) throws -> FilePath {
            let path = FilePath(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: false))
            let fmt = try EXT4.Formatter(path, minDiskSize: 32.kib())
            try fmt.create(path: "/original", mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: nil)
            try fmt.link(link: "/hardlink", target: "/original")
            if unlink {
                try fmt.unlink(path: "/hardlink")
            }
            try fmt.close()
            return path
        }

        let afterLink = try makeFile(unlink: false)
        #expect(try EXT4.EXT4Reader(blockDevice: afterLink).stat("/original").inode.linksCount == 2)

        let afterUnlink = try makeFile(unlink: true)
        #expect(try EXT4.EXT4Reader(blockDevice: afterUnlink).stat("/original").inode.linksCount == 1)
    }

    @Test func unlinkFirstInodeFreesInode() throws {
        let emptyPath = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: emptyPath.url) }
        try EXT4.Formatter(emptyPath, minDiskSize: 32.kib()).close()

        let path = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: path.url) }
        let fmt = try EXT4.Formatter(path, minDiskSize: 32.kib())
        try fmt.create(path: FilePath("/file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: nil)
        try fmt.unlink(path: FilePath("/file"))
        try fmt.close()

        #expect(try EXT4.EXT4Reader(blockDevice: path).superBlock.freeInodesCount == EXT4.EXT4Reader(blockDevice: emptyPath).superBlock.freeInodesCount)
    }
}
