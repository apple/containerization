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

import ContainerizationArchive
import Foundation
import SystemPackage
import Testing

@testable import Containerization
@testable import ContainerizationEXT4

/// Confirms that the `journal` configuration passed into `EXT4Unpacker.init` is actually
/// threaded through to the `EXT4.Formatter` it constructs, for both `unpack` overloads.
@Suite
struct EXT4UnpackerJournalTests {
    private let minDiskSize: UInt64 = 16.mib()

    @Test func unpackArchiveAppliesJournalConfig() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let outputPath = FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("ext4-unpacker-journal.img", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: outputPath) }

        let unpacker = EXT4Unpacker(capacityInBytes: minDiskSize, journal: .init(defaultMode: .ordered))
        try await unpacker.unpack(archive: archive, compression: .none, at: outputPath)

        try verifyJournaled(at: outputPath)
    }

    @Test func unpackArchiveWithoutJournalConfigOmitsJournal() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let outputPath = FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("ext4-unpacker-no-journal.img", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: outputPath) }

        let unpacker = EXT4Unpacker(capacityInBytes: minDiskSize)
        try await unpacker.unpack(archive: archive, compression: .none, at: outputPath)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(outputPath.absolutePath()))
        #expect(reader.superBlock.featureCompat & EXT4.CompatFeature.hasJournal.rawValue == 0)
    }

    // MARK: - Helpers

    private func verifyJournaled(at path: URL) throws {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(path.absolutePath()))
        let sb = reader.superBlock
        #expect(sb.featureCompat & EXT4.CompatFeature.hasJournal.rawValue != 0, "COMPAT_HAS_JOURNAL not set")
        #expect(sb.journalInum == EXT4.JournalInode, "journalInum=\(sb.journalInum), expected \(EXT4.JournalInode)")
    }

    private func makeArchive() throws -> URL {
        let archiveURL = FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("ext4-unpacker-journal.tar", isDirectory: false)
        let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: archiveURL)
        try writer.writeEntry(entry: .dir(path: "/data", permissions: 0o755), data: nil)
        let payload = Data("hello".utf8)
        try writer.writeEntry(
            entry: .file(path: "/data/hello.txt", permissions: 0o644, size: Int64(payload.count)),
            data: payload)
        try writer.finishEncoding()
        return archiveURL
    }
}

extension ContainerizationArchive.WriteEntry {
    fileprivate static func dir(path: String, permissions: mode_t) -> WriteEntry {
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .directory
        entry.permissions = permissions
        return entry
    }

    fileprivate static func file(path: String, permissions: mode_t, size: Int64) -> WriteEntry {
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .regular
        entry.permissions = permissions
        entry.size = size
        return entry
    }
}
