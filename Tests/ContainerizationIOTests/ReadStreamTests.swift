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
import NIO
import Testing

@testable import ContainerizationIO

struct ReadStreamTests {

    // MARK: - Initialization Tests

    @Test
    func testEmptyInit() {
        _ = ReadStream()
        // Test passes if no exceptions are thrown
    }

    @Test
    func testDataInit() {
        let testData = "Hello, World!".data(using: .utf8)!
        _ = ReadStream(data: testData)
        // Test passes if no exceptions are thrown
    }

    @Test
    func testDataInitWithCustomBufferSize() {
        let testData = "Hello, World!".data(using: .utf8)!
        let customBufferSize = 512
        _ = ReadStream(data: testData, bufferSize: customBufferSize)
        // Test passes if no exceptions are thrown
    }

    @Test
    func testURLInitWithValidFile() throws {
        // Create a temporary file
        let tempURL = createTemporaryFile(content: "Test file content")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try ReadStream(url: tempURL)
        // Test passes if no exceptions are thrown
    }

    @Test
    func testURLInitWithCustomBufferSize() throws {
        // Create a temporary file
        let tempURL = createTemporaryFile(content: "Test file content")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let customBufferSize = 1024
        _ = try ReadStream(url: tempURL, bufferSize: customBufferSize)
        // Test passes if no exceptions are thrown
    }

    @Test
    func testURLInitWithNonExistentFile() {
        let nonExistentURL = URL(fileURLWithPath: "/tmp/nonexistent_file_\(UUID().uuidString)")

        #expect(throws: ReadStream.Error.noSuchFileOrDirectory(nonExistentURL)) {
            _ = try ReadStream(url: nonExistentURL)
        }
    }

    // MARK: - Stream Reading Tests

    @Test
    func testDataStreamReading() async throws {
        let testContent = "Hello, World! This is a test string for streaming."
        let testData = testContent.data(using: .utf8)!
        let stream = ReadStream(data: testData)

        var receivedData = Data()

        for await chunk in stream.dataStream {
            receivedData.append(chunk)
        }

        let receivedString = String(data: receivedData, encoding: .utf8)
        #expect(receivedString == testContent)
    }

    @Test
    func testByteBufferStreamReading() async throws {
        let testContent = "Hello, World! This is a test string for streaming."
        let testData = testContent.data(using: .utf8)!
        let stream = ReadStream(data: testData)

        var receivedData = Data()

        for await buffer in stream.stream {
            let bytes = buffer.readableBytesView
            receivedData.append(contentsOf: bytes)
        }

        let receivedString = String(data: receivedData, encoding: .utf8)
        #expect(receivedString == testContent)
    }

    @Test
    func testFileStreamReading() async throws {
        let testContent = "This is test file content for streaming.\nWith multiple lines.\nAnd some special characters: éñüñö"
        let tempURL = createTemporaryFile(content: testContent)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let stream = try ReadStream(url: tempURL)

        var receivedData = Data()

        for await chunk in stream.dataStream {
            receivedData.append(chunk)
        }

        let receivedString = String(data: receivedData, encoding: .utf8)
        #expect(receivedString == testContent)
    }

    @Test
    func testEmptyDataStreaming() async throws {
        let stream = ReadStream()

        var chunkCount = 0
        for await _ in stream.dataStream {
            chunkCount += 1
        }

        // Empty stream should yield no chunks
        #expect(chunkCount == 0)
    }

    @Test
    func testEmptyByteBufferStreaming() async throws {
        let stream = ReadStream()

        var chunkCount = 0
        for await _ in stream.stream {
            chunkCount += 1
        }

        // Empty stream should yield no chunks
        #expect(chunkCount == 0)
    }

    @Test
    func testLargeFileStreaming() async throws {
        // Create a larger test content that will definitely exceed the buffer size
        let largeContent = String(repeating: "This is a test line with some content.\n", count: 5000)
        let tempURL = createTemporaryFile(content: largeContent)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Use a smaller buffer size to force multiple chunks
        let stream = try ReadStream(url: tempURL, bufferSize: 1024)

        var receivedData = Data()
        var chunkCount = 0

        for await chunk in stream.dataStream {
            receivedData.append(chunk)
            chunkCount += 1
        }

        let receivedString = String(data: receivedData, encoding: .utf8)
        #expect(receivedString == largeContent)
        #expect(chunkCount > 1)  // Should be split into multiple chunks
    }

    // MARK: - Reset Tests

    @Test
    func testResetDataStream() async throws {
        let testContent = "Hello, Reset Test!"
        let testData = testContent.data(using: .utf8)!
        let stream = ReadStream(data: testData)

        // Read once
        var firstRead = Data()
        for await chunk in stream.dataStream {
            firstRead.append(chunk)
        }

        // Reset and read again
        try stream.reset()

        var secondRead = Data()
        for await chunk in stream.dataStream {
            secondRead.append(chunk)
        }

        let firstString = String(data: firstRead, encoding: .utf8)
        let secondString = String(data: secondRead, encoding: .utf8)

        #expect(firstString == testContent)
        #expect(secondString == testContent)
        #expect(firstString == secondString)
    }

    @Test
    func testResetFileStream() async throws {
        let testContent = "File Reset Test Content"
        let tempURL = createTemporaryFile(content: testContent)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let stream = try ReadStream(url: tempURL)

        // Read once
        var firstRead = Data()
        for await chunk in stream.dataStream {
            firstRead.append(chunk)
        }

        // Reset and read again
        try stream.reset()

        var secondRead = Data()
        for await chunk in stream.dataStream {
            secondRead.append(chunk)
        }

        let firstString = String(data: firstRead, encoding: .utf8)
        let secondString = String(data: secondRead, encoding: .utf8)

        #expect(firstString == testContent)
        #expect(secondString == testContent)
        #expect(firstString == secondString)
    }

    @Test
    func testResetEmptyStream() async throws {
        let stream = ReadStream()

        // Reset should not throw for empty stream
        try stream.reset()

        var chunkCount = 0
        for await _ in stream.dataStream {
            chunkCount += 1
        }

        #expect(chunkCount == 0)
    }

    // MARK: - Error Tests

    @Test
    func testErrorDescriptions() {
        let url = URL(fileURLWithPath: "/tmp/test")
        let noFileError = ReadStream.Error.noSuchFileOrDirectory(url)
        let streamError = ReadStream.Error.failedToCreateStream

        #expect(noFileError.description.contains("/tmp/test"))
        #expect(streamError.description == "failed to create stream")
    }

    // MARK: - Buffer Size Tests

    @Test
    func testDefaultBufferSize() {
        #expect(ReadStream.bufferSize == Int(1.mib()))
    }

    @Test
    func testSmallBufferSize() async throws {
        let testContent = "This is a test with small buffer size that should be split into multiple chunks."
        let testData = testContent.data(using: .utf8)!
        let smallBufferSize = 10
        let stream = ReadStream(data: testData, bufferSize: smallBufferSize)

        var receivedData = Data()
        var chunkCount = 0

        for await chunk in stream.dataStream {
            receivedData.append(chunk)
            chunkCount += 1
            // Each chunk should be at most the buffer size
            #expect(chunk.count <= smallBufferSize)
        }

        let receivedString = String(data: receivedData, encoding: .utf8)
        #expect(receivedString == testContent)
        #expect(chunkCount > 1)  // Should be split into multiple chunks
    }

    // MARK: - Helper Methods

    private func createTemporaryFile(content: String) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("test_\(UUID().uuidString).txt")

        try! content.write(to: tempURL, atomically: true, encoding: .utf8)

        return tempURL
    }
}
