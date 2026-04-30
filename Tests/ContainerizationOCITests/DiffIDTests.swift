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

import ContainerizationError
import Crypto
import Foundation
import Testing

@testable import ContainerizationOCI

struct DiffIDTests {
    /// Helper to create a gzip-compressed temporary file from raw data.
    private func createGzipFile(content: Data) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let rawFile = tempDir.appendingPathComponent(UUID().uuidString)
        let gzFile = tempDir.appendingPathComponent(UUID().uuidString + ".gz")
        try content.write(to: rawFile)
        defer { try? FileManager.default.removeItem(at: rawFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", "-f", rawFile.path]
        try process.run()
        process.waitUntilExit()

        let gzPath = URL(fileURLWithPath: rawFile.path + ".gz")
        if FileManager.default.fileExists(atPath: gzPath.path) {
            try FileManager.default.moveItem(at: gzPath, to: gzFile)
        }
        return gzFile
    }

    @Test func diffIDMatchesUncompressedSHA256() throws {
        let content = Data("hello, oci layer content for diffid test".utf8)
        let gzFile = try createGzipFile(content: content)
        defer { try? FileManager.default.removeItem(at: gzFile) }

        let diffID = try ContentWriter.diffID(of: gzFile)
        let expected = SHA256.hash(data: content)

        #expect(diffID.digestString == expected.digestString)
    }

    @Test func diffIDIsDeterministic() throws {
        let content = Data("deterministic diffid check".utf8)
        let gzFile = try createGzipFile(content: content)
        defer { try? FileManager.default.removeItem(at: gzFile) }

        let first = try ContentWriter.diffID(of: gzFile)
        let second = try ContentWriter.diffID(of: gzFile)

        #expect(first.digestString == second.digestString)
    }

    @Test func diffIDRejectsNonGzipData() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("this is not gzip".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        #expect(throws: ContainerizationError.self) {
            try ContentWriter.diffID(of: tempFile)
        }
    }

    @Test func diffIDRejectsEmptyFile() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        #expect(throws: ContainerizationError.self) {
            try ContentWriter.diffID(of: tempFile)
        }
    }

    @Test func diffIDHandlesLargeContent() throws {
        // 1MB of repeating data
        let pattern = Data("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345".utf8)
        var large = Data()
        for _ in 0..<(1_048_576 / pattern.count) {
            large.append(pattern)
        }
        let gzFile = try createGzipFile(content: large)
        defer { try? FileManager.default.removeItem(at: gzFile) }

        let diffID = try ContentWriter.diffID(of: gzFile)
        let expected = SHA256.hash(data: large)

        #expect(diffID.digestString == expected.digestString)
    }

    @Test func diffIDRejectsTruncatedGzip() throws {
        // Build a valid gzip file, then chop off the 8-byte trailer (CRC32 + ISIZE)
        // to produce a structurally malformed archive.
        let content = Data("truncated gzip trailer test".utf8)
        let gzFile = try createGzipFile(content: content)
        defer { try? FileManager.default.removeItem(at: gzFile) }

        var gzData = try Data(contentsOf: gzFile)
        guard gzData.count > 8 else {
            Issue.record("Compressed file too small to truncate")
            return
        }
        gzData.removeLast(8)

        let truncatedFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gz")
        try gzData.write(to: truncatedFile)
        defer { try? FileManager.default.removeItem(at: truncatedFile) }

        #expect(throws: ContainerizationError.self) {
            try ContentWriter.diffID(of: truncatedFile)
        }
    }

    @Test func diffIDRejectsCorruptedCRC() throws {
        // Flip a byte in the CRC32 field of an otherwise valid gzip file.
        let content = Data("corrupted crc test".utf8)
        let gzFile = try createGzipFile(content: content)
        defer { try? FileManager.default.removeItem(at: gzFile) }

        var gzData = try Data(contentsOf: gzFile)
        let crcOffset = gzData.count - 8
        gzData[crcOffset] ^= 0xFF

        let corruptedFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gz")
        try gzData.write(to: corruptedFile)
        defer { try? FileManager.default.removeItem(at: corruptedFile) }

        #expect(throws: ContainerizationError.self) {
            try ContentWriter.diffID(of: corruptedFile)
        }
    }

    @Test func diffIDDigestStringFormat() throws {
        let content = Data("format test".utf8)
        let gzFile = try createGzipFile(content: content)
        defer { try? FileManager.default.removeItem(at: gzFile) }

        let diffID = try ContentWriter.diffID(of: gzFile)
        let digestString = diffID.digestString

        #expect(digestString.hasPrefix("sha256:"))
        // sha256: prefix + 64 hex chars
        #expect(digestString.count == 7 + 64)
    }
}
