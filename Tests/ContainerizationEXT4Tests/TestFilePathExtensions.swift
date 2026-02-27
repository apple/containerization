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

struct TestFilePathExtensions {
    @Test func testFilePathBytes() {
        let path = FilePath("/test/path")
        let bytes = path.bytes
        let expected = "/test/path".utf8.map { UInt8($0) }
        #expect(bytes == expected)
    }

    @Test func testFilePathBase() {
        let path1 = FilePath("/test/path/file.txt")
        #expect(path1.base == "file.txt")

        let path2 = FilePath("/")
        #expect(path2.base == "/")

        let path3 = FilePath("/single")
        #expect(path3.base == "single")
    }

    @Test func testFilePathDir() {
        let path = FilePath("/test/path/file.txt")
        #expect(path.dir == FilePath("/test/path"))

        let rootPath = FilePath("/")
        #expect(rootPath.dir == FilePath("/"))
    }

    @Test func testFilePathURL() {
        let path = FilePath("/test/path")
        let url = path.url
        #expect(url == URL(fileURLWithPath: "/test/path"))
    }

    @Test func testFilePathItems() {
        let path = FilePath("/test/path/file.txt")
        let items = path.items
        #expect(items == ["test", "path", "file.txt"])

        let rootPath = FilePath("/")
        #expect(rootPath.items == [])
    }

    @Test func testFilePathInitFromURL() {
        let url = URL(fileURLWithPath: "/test/path")
        let path = FilePath(url)
        #expect(path == FilePath("/test/path"))
    }

    @Test func testFilePathInitFromData() {
        let data = "/test/path\0".data(using: .utf8)!
        let path = FilePath(data)
        #expect(path == FilePath("/test/path"))

        // Test with empty data - creates empty path, not nil
        let emptyData = Data()
        let emptyPath = FilePath(emptyData)
        #expect(emptyPath == FilePath(""))

        // Test with null terminator only - should create empty path
        let nullData = Data([0x00])
        let nullPath = FilePath(nullData)
        #expect(nullPath == FilePath(""))
    }

    @Test func testFilePathJoin() {
        let base = FilePath("/test")
        let joined1 = base.join(FilePath("path"))
        #expect(joined1 == FilePath("/test/path"))

        let joined2 = base.join("file.txt")
        #expect(joined2 == FilePath("/test/file.txt"))
    }

    @Test func testFilePathSplit() {
        let path = FilePath("/test/path/file.txt")
        let (dir, base) = path.split()
        #expect(dir == FilePath("/test/path"))
        #expect(base == "file.txt")
    }

    @Test func testFilePathClean() {
        let path = FilePath("/test/../test/./path")
        let cleaned = path.clean()
        #expect(cleaned == FilePath("/test/path"))
    }

    @Test func testFilePathRel() {
        let base = "/test/common/base"
        let target = "/test/common/target/file.txt"
        let rel = FilePath.rel(base, target)
        #expect(rel == FilePath("../target/file.txt"))

        let sameBase = "/test/path"
        let sameTarget = "/test/path"
        let sameRel = FilePath.rel(sameBase, sameTarget)
        #expect(sameRel == FilePath("."))

        let differentBase = "/completely/different/path"
        let differentTarget = "/other/path"
        let differentRel = FilePath.rel(differentBase, differentTarget)
        #expect(differentRel == FilePath("../../../other/path"))
    }

    @Test func testFileHandleExtensions() {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_file.txt")
        let testPath = FilePath(testFile.path)

        // Create a test file
        try! "test content".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Test reading
        let readHandle = FileHandle(forReadingFrom: testPath)
        #expect(readHandle != nil)

        let readHandle2 = FileHandle(forReadingAtPath: testPath)
        #expect(readHandle2 != nil)

        // Test writing
        let writeHandle = FileHandle(forWritingTo: testPath)
        #expect(writeHandle != nil)

        // Test non-existent file
        let nonExistentPath = FilePath("/non/existent/path")
        let nonExistentHandle = FileHandle(forReadingFrom: nonExistentPath)
        #expect(nonExistentHandle == nil)
    }
}
