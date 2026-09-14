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

@Suite("ContentWriter Tests")
struct ContentWriterTests {
    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func makeTempFile(in dir: URL, data: Data) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    @Test func testWriteReturnsCorrectSizeAndDigest() throws {
        try withTempDirectory { dir in
            let writer = try ContentWriter(for: dir)
            let data = Data("test content".utf8)
            let (size, digest) = try writer.write(data)
            let expected = SHA256.hash(data: data)
            let destination = dir.appendingPathComponent(digest.encoded)
            #expect(size == Int64(data.count))
            #expect(digest == expected)
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func testWriteDuplicateData() throws {
        try withTempDirectory { dir in
            let writer = try ContentWriter(for: dir)
            let data = Data("duplicate".utf8)
            #expect(throws: Never.self) {
                try writer.write(data)
                try writer.write(data)
            }
        }
    }

    @Test func testCreateFromFileSmallFile() throws {
        try withTempDirectory { base in
            try withTempDirectory { src in
                let data = Data("small file contents".utf8)
                let sourceURL = try makeTempFile(in: src, data: data)
                let writer = try ContentWriter(for: base)
                let (size, digest) = try writer.create(from: sourceURL)
                let destination = base.appendingPathComponent(digest.encoded)
                let written = try Data(contentsOf: destination)
                #expect(size == Int64(data.count))
                #expect(digest == SHA256.hash(data: data))
                #expect(FileManager.default.fileExists(atPath: destination.path))
                #expect(written == data)
            }
        }
    }

    @Test func testCreateFromFileLargeFileDuplicates() throws {
        try withTempDirectory { base in
            try withTempDirectory { src in
                let count = 3 * 1024 * 1024 + 100
                var bytes = [UInt8](repeating: 0, count: count)
                arc4random_buf(&bytes, count)
                let data = Data(bytes)
                let sourceURL = try makeTempFile(in: src, data: data)
                let writer = try ContentWriter(for: base)
                let (size, digest) = try writer.create(from: sourceURL)
                let destination = base.appendingPathComponent(digest.encoded)
                #expect(size == Int64(data.count))
                #expect(digest == SHA256.hash(data: data))
                #expect(throws: Never.self) {
                    try writer.create(from: sourceURL)
                }
                #expect(FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }

    private struct SamplePayload: Codable, Equatable {
        let name: String
        let value: Int
    }

    @Test func testCreateFromEncodableReturnsCorrectDigest() throws {
        try withTempDirectory { base in
            let writer = try ContentWriter(for: base)
            let payload = SamplePayload(name: "digest-check", value: 99)
            let (size, digest) = try writer.create(from: payload)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let expected = try encoder.encode(payload)
            #expect(size == Int64(expected.count))
            #expect(digest == SHA256.hash(data: expected))
        }
    }

    @Test func testCreateFromRejectsSymlinkedSource() throws {
        try withTempDirectory { base in
            try withTempDirectory { src in
                let target = try makeTempFile(in: src, data: Data("target contents".utf8))
                let link = src.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

                let writer = try ContentWriter(for: base)
                #expect(throws: (any Error).self) {
                    try writer.create(from: link)
                }
            }
        }
    }

    @Test func testCopyFromToRejectsSymlinkedSource() throws {
        try withTempDirectory { base in
            try withTempDirectory { src in
                let target = try makeTempFile(in: src, data: Data("target contents".utf8))
                let link = src.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

                let destination = base.appendingPathComponent(UUID().uuidString)
                #expect(throws: (any Error).self) {
                    try ContentWriter.copy(from: link, destination: destination)
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }

    @Test func testCopyFromToRoundTripsRegularFile() throws {
        try withTempDirectory { base in
            try withTempDirectory { src in
                let data = Data("copy me".utf8)
                let sourceURL = try makeTempFile(in: src, data: data)
                let destination = base.appendingPathComponent(UUID().uuidString)

                let (size, digest) = try ContentWriter.copy(from: sourceURL, destination: destination)
                let written = try Data(contentsOf: destination)
                #expect(size == Int64(data.count))
                #expect(digest == SHA256.hash(data: data))
                #expect(written == data)
            }
        }
    }

    @Test func testCopyFromToRejectsExistingDestination() throws {
        try withTempDirectory { base in
            try withTempDirectory { src in
                let data = Data("copy me".utf8)
                let sourceURL = try makeTempFile(in: src, data: data)
                let destination = base.appendingPathComponent(UUID().uuidString)
                let existingData = Data("stale contents".utf8)
                try existingData.write(to: destination)

                #expect(throws: (any Error).self) {
                    try ContentWriter.copy(from: sourceURL, destination: destination)
                }
                // The pre-existing destination content is left untouched, not overwritten.
                #expect(try Data(contentsOf: destination) == existingData)
            }
        }
    }
}
