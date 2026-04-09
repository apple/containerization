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

//

import Foundation
import SystemPackage
import Testing

@testable import ContainerizationEXT4

struct Ext4FormatCreateTests {
    @Test func fileReplace() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        defer { try? formatter.close() }
        try formatter.create(path: FilePath("/file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: nil)  // create a regular file
        #expect(throws: Never.self) {
            try formatter.create(path: FilePath("/file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: nil)
        }  // overwrite it with a regular file
        #expect(throws: Error.self) { try formatter.create(path: FilePath("/file"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o700)) }  // overwrite it with a directory
    }

    @Test func dirReplace() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        defer { try? formatter.close() }
        try formatter.create(path: FilePath("/dir"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o700))  // create a directory
        #expect(throws: Never.self) {
            try formatter.create(path: FilePath("/dir"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o700))
        }  // overwrite it with a directory
        #expect(throws: Error.self) { try formatter.create(path: FilePath("/dir"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755)) }  // overwrite it with a file
    }

    @Test func fileParentFails() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        defer { try? formatter.close() }
        try formatter.create(path: FilePath("/file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: nil)  // create a regular file
        #expect(throws: Error.self) { try formatter.create(path: FilePath("/file/dir"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o700)) }  // create a subdir in a file?
    }

    @Test func createParentAutomatically() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: fsPath.url) }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        defer { try? formatter.close() }
        #expect(throws: Never.self) {
            try formatter.create(path: FilePath("/parent/file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: nil)
        }  // should create /parent automatically
    }
}
