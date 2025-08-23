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
import Testing

@testable import ContainerizationExtras

struct FileManagerTemporaryTests {

    // MARK: - uniqueTemporaryDirectory Tests

    @Test func uniqueTemporaryDirectoryCreatesUniqueDirectories() throws {
        let fileManager = FileManager.default

        let tempDir1 = fileManager.uniqueTemporaryDirectory(create: true)
        let tempDir2 = fileManager.uniqueTemporaryDirectory(create: true)

        // Directories should be different
        #expect(tempDir1 != tempDir2)

        // Both should exist
        #expect(fileManager.fileExists(atPath: tempDir1.path))
        #expect(fileManager.fileExists(atPath: tempDir2.path))

        // Both should be under the system temporary directory
        let systemTempDir = fileManager.temporaryDirectory
        #expect(tempDir1.path.hasPrefix(systemTempDir.path))
        #expect(tempDir2.path.hasPrefix(systemTempDir.path))

        // Clean up
        try? fileManager.removeItem(at: tempDir1)
        try? fileManager.removeItem(at: tempDir2)
    }

    @Test func uniqueTemporaryDirectoryWithCreateFalse() throws {
        let fileManager = FileManager.default

        let tempDir = fileManager.uniqueTemporaryDirectory(create: false)

        // Directory should not exist
        #expect(!fileManager.fileExists(atPath: tempDir.path))

        // Should be under the system temporary directory
        let systemTempDir = fileManager.temporaryDirectory
        #expect(tempDir.path.hasPrefix(systemTempDir.path))

        // Should contain a UUID string component
        #expect(tempDir.lastPathComponent.count == 36)  // UUID string length
    }

    @Test func uniqueTemporaryDirectoryDefaultBehaviorCreatesDirectory() throws {
        let fileManager = FileManager.default

        let tempDir = fileManager.uniqueTemporaryDirectory()

        // Directory should exist (default create: true)
        #expect(fileManager.fileExists(atPath: tempDir.path))

        // Clean up
        try? fileManager.removeItem(at: tempDir)
    }

    @Test func uniqueTemporaryDirectoryPathStructure() throws {
        let fileManager = FileManager.default

        let tempDir = fileManager.uniqueTemporaryDirectory(create: false)
        let components = tempDir.pathComponents

        // Should have proper structure: system temp + UUID
        #expect(components.count >= 2)

        // Last component should be UUID-like (36 characters with hyphens)
        let uuidComponent = tempDir.lastPathComponent
        #expect(uuidComponent.count == 36)
        #expect(uuidComponent.contains("-"))

        // Should be parseable as UUID
        #expect(UUID(uuidString: uuidComponent) != nil)
    }

    @Test func uniqueTemporaryDirectoryIsWritable() throws {
        let fileManager = FileManager.default

        let tempDir = fileManager.uniqueTemporaryDirectory(create: true)

        // Should be able to create a file inside
        let testFile = tempDir.appendingPathComponent("test.txt")
        let testData = "test content".data(using: .utf8)!

        #expect(throws: Never.self) {
            try testData.write(to: testFile)
        }

        // File should exist and have correct content
        #expect(fileManager.fileExists(atPath: testFile.path))
        let readData = try Data(contentsOf: testFile)
        #expect(readData == testData)

        // Clean up
        try? fileManager.removeItem(at: tempDir)
    }
}
