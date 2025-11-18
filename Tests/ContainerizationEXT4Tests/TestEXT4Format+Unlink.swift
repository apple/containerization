//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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

import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

struct EXT4WhiteoutTests {

    private func makeTempFileURL(prefix: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        return url
    }

    private func writeLayerWithOpaqueWhiteout(to url: URL) throws {
        let writer = try ArchiveWriter(
            format: .pax,
            filter: .gzip,
            file: url
        )

        let ts = Date()

        let entry = WriteEntry()
        entry.modificationDate = ts
        entry.creationDate = ts
        entry.owner = 0
        entry.group = 0

        entry.fileType = .directory
        entry.permissions = 0o755

        entry.path = "usr"
        try writer.writeEntry(entry: entry, data: nil)

        entry.path = "usr/local"
        try writer.writeEntry(entry: entry, data: nil)

        entry.path = "usr/local/bin"
        try writer.writeEntry(entry: entry, data: nil)

        entry.fileType = .regular
        entry.permissions = 0o644

        let fooData = Data("hello\n".utf8)
        entry.path = "usr/local/bin/foo"
        entry.size = Int64(fooData.count)
        try writer.writeEntry(entry: entry, data: fooData)

        entry.fileType = .regular
        entry.permissions = 0o000
        entry.size = 0
        entry.path = "usr//.wh..wh..opq"
        try writer.writeEntry(entry: entry, data: nil)

        try writer.finishEncoding()
    }

    private func withFormatter<T>(
        prefix: String = "ext4-whiteout",
        blockSize: UInt32 = 4096,
        minDiskSize: UInt64 = 16.mib(),
        _ body: (EXT4.Formatter, FilePath) throws -> T
    ) throws -> T {
        let imageURL = try makeTempFileURL(prefix: prefix)
        let imagePath = FilePath(imageURL.path)

        defer {
            try? FileManager.default.removeItem(at: imageURL)
        }

        let formatter = try EXT4.Formatter(
            imagePath,
            blockSize: blockSize,
            minDiskSize: minDiskSize
        )

        let result = try body(formatter, imagePath)
        return result
    }

    @Test
    func unpack_with_opaque_whiteout_path_does_not_stack_overflow_and_cleans_directory() throws {
        let layerURL = try makeTempFileURL(prefix: "ext4-wh-layer")
        defer {
            try? FileManager.default.removeItem(at: layerURL)
        }

        try writeLayerWithOpaqueWhiteout(to: layerURL)

        try withFormatter { formatter, imagePath in
            try formatter.unpack(
                source: FilePath(layerURL.path).url,
                format: .pax,
                compression: .gzip,
                progress: nil
            )

            try formatter.close()

            let reader = try EXT4.EXT4Reader(blockDevice: FilePath(imagePath.description))

            #expect(reader.exists(FilePath("/usr/local/bin")) == false)

            #expect(reader.exists(FilePath("/usr/local/bin/foo")) == false)
        }
    }

    @Test
    func directoryWhiteout_from_wh_opq_path_with_repeated_slashes_terminates() throws {
        try withFormatter { formatter, _ in
            try formatter.create(
                path: FilePath("/usr"),
                mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
            )
            try formatter.create(
                path: FilePath("/usr/local"),
                mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
            )
            try formatter.create(
                path: FilePath("/usr/local/bin"),
                mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
            )
            try formatter.create(
                path: FilePath("/usr/local/bin/foo"),
                mode: EXT4.Inode.Mode(.S_IFREG, 0o644)
            )
            try formatter.create(
                path: FilePath("/usr/local/bin/bar"),
                mode: EXT4.Inode.Mode(.S_IFREG, 0o644)
            )

            let whiteoutEntry = FilePath("//usr//.wh..wh..opq")
            let directoryToWhiteout = whiteoutEntry.dir
            let normalized = directoryToWhiteout.lexicallyNormalized()
            #expect(normalized == FilePath("/usr"))
            try formatter.unlink(path: directoryToWhiteout, directoryWhiteout: true)
        }
    }

    /// Test the exact recursion attack sequence:
    /// create /_d
    /// create symlink / -> /_
    /// create /_
    /// create symlink / -> /_
    ///
    /// This creates a recursive symlink structure that can cause infinite recursion
    /// during directory traversal operations.
    @Test
    func recursion_attack_sequence_does_not_cause_infinite_recursion() throws {
        #expect(throws: EXT4.Formatter.Error.unsupportedFiletype) {
            try withFormatter { formatter, _ in
                // Step 1: create /_d
                try formatter.create(
                    path: FilePath("/_d"),
                    mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
                )

                // Step 2: create symlink / -> /_
                try formatter.create(
                    path: FilePath("/"),
                    link: FilePath("/_"),
                    mode: EXT4.Inode.Mode(.S_IFLNK, 0o777)
                )

                try formatter.create(
                    path: FilePath("/_"),
                    mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
                )

                try formatter.create(
                    path: FilePath("/"),
                    link: FilePath("/_"),
                    mode: EXT4.Inode.Mode(.S_IFLNK, 0o777)
                )
            }
        }
    }

    @Test
    func file_whiteouts_and_directory_whiteouts_interact_correctly() throws {
        try withFormatter { formatter, imagePath in
            // Lower‑layer content
            try formatter.create(
                path: FilePath("/opt"),
                mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
            )
            try formatter.create(
                path: FilePath("/opt/app"),
                mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
            )
            try formatter.create(
                path: FilePath("/opt/app/cache"),
                mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
            )
            try formatter.create(
                path: FilePath("/opt/app/cache/file"),
                mode: EXT4.Inode.Mode(.S_IFREG, 0o644)
            )
            try formatter.unlink(path: FilePath("/opt/app/cache/file"))
            try formatter.unlink(
                path: FilePath("/opt/app/cache"),
                directoryWhiteout: true
            )
            try formatter.close()

            let reader = try EXT4.EXT4Reader(blockDevice: FilePath(imagePath.description))
            #expect(reader.exists(FilePath("/opt")))
            #expect(reader.exists(FilePath("/opt/app")))
            #expect(reader.exists(FilePath("/opt/app/cache")))
            #expect(reader.exists(FilePath("/opt/app/cache/file")) == false)
        }
    }
}
