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

#if os(macOS)
import Foundation
import SystemPackage
import Testing

@testable import ContainerizationEXT4

struct TestEXT4ReaderExport {
    @Test func testEXT4ReaderExportBasic() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".ext4", isDirectory: false))
        let archivePath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".tar", isDirectory: false))

        defer {
            try? FileManager.default.removeItem(at: fsPath.url)
            try? FileManager.default.removeItem(at: archivePath.url)
        }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        try formatter.create(path: FilePath("/test_dir"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.create(path: FilePath("/test_file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: nil)
        try formatter.create(path: FilePath("/test_symlink"), link: FilePath("test_file"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        try reader.export(archive: archivePath)

        #expect(FileManager.default.fileExists(atPath: archivePath.description))

        let archiveSize = try FileManager.default.attributesOfItem(atPath: archivePath.description)[.size] as? Int64 ?? 0
        #expect(archiveSize > 0)
    }

    @Test func testEXT4ReaderExportWithContent() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".ext4", isDirectory: false))
        let archivePath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".tar", isDirectory: false))

        defer {
            try? FileManager.default.removeItem(at: fsPath.url)
            try? FileManager.default.removeItem(at: archivePath.url)
        }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())

        let testContent = "Hello, World!"
        let inputStream = InputStream(data: testContent.data(using: .utf8)!)
        inputStream.open()
        defer { inputStream.close() }

        try formatter.create(path: FilePath("/test_file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: inputStream)
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        try reader.export(archive: archivePath)

        #expect(FileManager.default.fileExists(atPath: archivePath.description))

        let archiveSize = try FileManager.default.attributesOfItem(atPath: archivePath.description)[.size] as? Int64 ?? 0
        #expect(archiveSize > 0)
    }

    @Test func testEXT4ReaderExportWithHardlinks() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".ext4", isDirectory: false))
        let archivePath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".tar", isDirectory: false))

        defer {
            try? FileManager.default.removeItem(at: fsPath.url)
            try? FileManager.default.removeItem(at: archivePath.url)
        }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())

        let testContent = "Hardlink content"
        let inputStream = InputStream(data: testContent.data(using: .utf8)!)
        inputStream.open()
        defer { inputStream.close() }

        try formatter.create(path: FilePath("/original_file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: inputStream)
        try formatter.link(link: FilePath("/hardlink_file"), target: FilePath("/original_file"))
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        try reader.export(archive: archivePath)

        #expect(FileManager.default.fileExists(atPath: archivePath.description))

        let archiveSize = try FileManager.default.attributesOfItem(atPath: archivePath.description)[.size] as? Int64 ?? 0
        #expect(archiveSize > 0)
    }

    @Test func testEXT4ReaderExportEmptyFilesystem() throws {
        let fsPath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".ext4", isDirectory: false))
        let archivePath = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".tar", isDirectory: false))

        defer {
            try? FileManager.default.removeItem(at: fsPath.url)
            try? FileManager.default.removeItem(at: archivePath.url)
        }

        let formatter = try EXT4.Formatter(fsPath, minDiskSize: 32.kib())
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
        try reader.export(archive: archivePath)

        #expect(FileManager.default.fileExists(atPath: archivePath.description))

        let archiveSize = try FileManager.default.attributesOfItem(atPath: archivePath.description)[.size] as? Int64 ?? 0
        #expect(archiveSize > 0)
    }
}
#endif
