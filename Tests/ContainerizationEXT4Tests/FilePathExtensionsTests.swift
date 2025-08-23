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

struct FilePathExtensionsTests {

    // MARK: - bytes Tests

    @Test func bytesConvertsPathToUInt8Array() throws {
        let path = FilePath("/usr/bin")
        let bytes = path.bytes

        // Should contain the path as bytes
        #expect(!bytes.isEmpty)

        // Verify it matches the expected string bytes
        let expected = Array("/usr/bin".utf8)
        #expect(bytes == expected)
    }

    @Test func bytesHandlesEmptyPath() throws {
        let path = FilePath("")
        let bytes = path.bytes

        #expect(bytes.isEmpty)
    }

    @Test func bytesHandlesSpecialCharacters() throws {
        let path = FilePath("/tmp/test file.txt")
        let bytes = path.bytes

        let expected = Array("/tmp/test file.txt".utf8)
        #expect(bytes == expected)
    }

    // MARK: - base Tests

    @Test func baseReturnsLastComponent() throws {
        let path = FilePath("/usr/local/bin")
        let base = path.base

        #expect(base == "bin")
    }

    @Test func baseReturnsFileNameWithExtension() throws {
        let path = FilePath("/home/user/document.txt")
        let base = path.base

        #expect(base == "document.txt")
    }

    @Test func baseHandlesRootPath() throws {
        let path = FilePath("/")
        let base = path.base

        #expect(base == "/")
    }

    @Test func baseHandlesSingleComponent() throws {
        let path = FilePath("filename.txt")
        let base = path.base

        #expect(base == "filename.txt")
    }

    // MARK: - dir Tests

    @Test func dirReturnsParentDirectory() throws {
        let path = FilePath("/usr/local/bin")
        let dir = path.dir

        #expect(dir == FilePath("/usr/local"))
    }

    @Test func dirHandlesRootPath() throws {
        let path = FilePath("/")
        let dir = path.dir

        #expect(dir == FilePath("/"))
    }

    @Test func dirHandlesSingleLevel() throws {
        let path = FilePath("/tmp")
        let dir = path.dir

        #expect(dir == FilePath("/"))
    }

    // MARK: - url Tests

    @Test func urlConvertsToFoundationURL() throws {
        let path = FilePath("/usr/local/bin")
        let url = path.url

        #expect(url.path == "/usr/local/bin")
        #expect(url.isFileURL)
    }

    // MARK: - items Tests

    @Test func itemsReturnsPathComponents() throws {
        let path = FilePath("/usr/local/bin")
        let items = path.items

        // FilePath.items maps components, absolute paths don't include root "/"
        #expect(items == ["usr", "local", "bin"])
    }

    @Test func itemsHandlesRootPath() throws {
        let path = FilePath("/")
        let items = path.items

        // Root path has empty components array
        #expect(items == [])
    }

    @Test func itemsHandlesRelativePath() throws {
        let path = FilePath("usr/local")
        let items = path.items

        #expect(items == ["usr", "local"])
    }

    // MARK: - init(URL) Tests

    @Test func initFromURLCreatesCorrectPath() throws {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        let path = FilePath(url)

        #expect(path == FilePath("/tmp/test.txt"))
    }

    // MARK: - init(Data) Tests

    @Test func initFromDataSucceedsWithValidCString() throws {
        let pathString = "/usr/bin/swift"
        let data = Data(pathString.utf8 + [0])  // Null-terminated
        let path = FilePath(data)

        #expect(path != nil)
        #expect(path == FilePath(pathString))
    }

    @Test func initFromDataFailsWithInvalidData() throws {
        let data = Data()  // Empty data
        let path = FilePath(data)

        // Empty data actually creates an empty path, not nil
        #expect(path != nil)
        #expect(path?.string == "")
    }

    @Test func initFromDataHandlesNullTermination() throws {
        let pathString = "/home/user"
        let data = Data(pathString.utf8 + [0])  // Null-terminated
        let path = FilePath(data)

        #expect(path != nil)
        #expect(path?.string == pathString)
    }

    // MARK: - join Tests

    @Test func joinCombinesPathsCorrectly() throws {
        let basePath = FilePath("/usr/local")
        let subPath = FilePath("bin")
        let joined = basePath.join(subPath)

        #expect(joined == FilePath("/usr/local/bin"))
    }

    @Test func joinWithStringCombinesCorrectly() throws {
        let basePath = FilePath("/home/user")
        let joined = basePath.join("documents")

        #expect(joined == FilePath("/home/user/documents"))
    }

    @Test func joinHandlesAbsolutePaths() throws {
        let basePath = FilePath("/usr")
        let absolutePath = FilePath("/tmp")
        let joined = basePath.join(absolutePath)

        // When joining with absolute path, it should replace the base
        #expect(joined == FilePath("/tmp"))
    }

    // MARK: - split Tests

    @Test func splitReturnsDirectoryAndBase() throws {
        let path = FilePath("/usr/local/bin")
        let (dir, base) = path.split()

        #expect(dir == FilePath("/usr/local"))
        #expect(base == "bin")
    }

    @Test func splitHandlesRootPath() throws {
        let path = FilePath("/")
        let (dir, base) = path.split()

        #expect(dir == FilePath("/"))
        #expect(base == "/")
    }

    // MARK: - clean Tests

    @Test func cleanNormalizesPath() throws {
        let path = FilePath("/usr/local/../bin/./swift")
        let cleaned = path.clean()

        // Should normalize to /usr/bin/swift
        #expect(cleaned == FilePath("/usr/bin/swift"))
    }

    @Test func cleanHandlesCurrentDirectory() throws {
        let path = FilePath("./usr/bin")
        let cleaned = path.clean()

        #expect(cleaned == FilePath("usr/bin"))
    }

    @Test func cleanHandlesParentDirectory() throws {
        let path = FilePath("/usr/local/../local/bin")
        let cleaned = path.clean()

        #expect(cleaned == FilePath("/usr/local/bin"))
    }

    // MARK: - rel (relative path) Tests

    @Test func relCalculatesSimpleRelativePath() throws {
        let base = "/usr/local"
        let target = "/usr/local/bin"
        let relative = FilePath.rel(base, target)

        #expect(relative == FilePath("bin"))
    }

    @Test func relCalculatesUpwardRelativePath() throws {
        let base = "/usr/local/bin"
        let target = "/usr/share"
        let relative = FilePath.rel(base, target)

        #expect(relative == FilePath("../../share"))
    }

    @Test func relHandlesIdenticalPaths() throws {
        let base = "/usr/local/bin"
        let target = "/usr/local/bin"
        let relative = FilePath.rel(base, target)

        #expect(relative == FilePath("."))
    }

    @Test func relCalculatesComplexRelativePath() throws {
        let base = "/home/user/projects/app"
        let target = "/home/user/documents/file.txt"
        let relative = FilePath.rel(base, target)

        #expect(relative == FilePath("../../documents/file.txt"))
    }

    @Test func relHandlesRootPaths() throws {
        let base = "/"
        let target = "/usr/bin"
        let relative = FilePath.rel(base, target)

        #expect(relative == FilePath("usr/bin"))
    }

    @Test func relFromDeepToRoot() throws {
        let base = "/usr/local/bin/deep"
        let target = "/"
        let relative = FilePath.rel(base, target)

        #expect(relative == FilePath("../../../.."))
    }

    @Test func relBetweenSiblingDirectories() throws {
        let base = "/usr/local/bin"
        let target = "/usr/local/lib"
        let relative = FilePath.rel(base, target)

        #expect(relative == FilePath("../lib"))
    }

    @Test func relNoCommonPrefix() throws {
        let base = "/usr/local"
        let target = "/home/user"
        let relative = FilePath.rel(base, target)

        #expect(relative == FilePath("../../home/user"))
    }

    // MARK: - Integration Tests

    @Test func pathManipulationIntegration() throws {
        let originalPath = FilePath("/home/user/documents/../projects/./app")
        let cleanedPath = originalPath.clean()
        let (dir, base) = cleanedPath.split()
        let rejoined = dir.join(base)

        #expect(cleanedPath == FilePath("/home/user/projects/app"))
        #expect(dir == FilePath("/home/user/projects"))
        #expect(base == "app")
        #expect(rejoined == cleanedPath)
    }

    @Test func bytesAndDataRoundTrip() throws {
        let originalPath = FilePath("/tmp/test file.txt")
        let bytes = originalPath.bytes
        let data = Data(bytes + [0])  // Add null terminator
        let reconstructedPath = FilePath(data)

        #expect(reconstructedPath != nil)
        #expect(reconstructedPath == originalPath)
    }
}
