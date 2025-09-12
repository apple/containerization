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

@testable import Containerization
@testable import ContainerizationError

final class MountTests {
    @Test func mountShareCreatesVirtiofsMount() {
        let mount = Mount.share(
            source: "/host/shared",
            destination: "/guest/shared",
            options: ["rw", "noatime"],
            runtimeOptions: ["tag=shared"]
        )

        #expect(mount.type == "virtiofs")
        #expect(mount.source == "/host/shared")
        #expect(mount.destination == "/guest/shared")
        #expect(mount.options == ["rw", "noatime"])

        if case .virtiofs(let opts) = mount.runtimeOptions {
            #expect(opts == ["tag=shared"])
        } else {
            #expect(Bool(false), "Expected virtiofs runtime options")
        }
    }

    @Test func fileDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("testfile-\(#function).txt")

        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let mount = Mount.share(
            source: testFile.path,
            destination: "/app/config.txt"
        )

        #expect(mount.isFile == true)
        #expect(mount.filename.hasPrefix("testfile-"))
        #expect(mount.parentDirectory == tempDir.path)
    }

    @Test func directoryDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory

        let mount = Mount.share(
            source: tempDir.path,
            destination: "/app/data"
        )

        #expect(mount.isFile == false)
    }

    #if os(macOS)
    @Test func attachedFilesystemBindFlag() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("bindtest-\(#function).txt")

        try "bind test".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let mount = Mount.share(
            source: testFile.path,
            destination: "/app/config-\(#function).txt"
        )

        let allocator = Character.blockDeviceTagAllocator()
        let attached = try AttachedFilesystem(mount: mount, allocator: allocator)

        #expect(attached.isFile == true)
        #expect(attached.type == "virtiofs")
    }

    @Test func nonExistentFileMount() throws {
        let nonExistentFile = "/path/that/does/not/exist.txt"

        let mount = Mount.share(
            source: nonExistentFile,
            destination: "/app/config.txt"
        )

        #expect(mount.isFile == false)  // Non-existent files are treated as directories
        #expect(mount.filename == "exist.txt")
        #expect(mount.parentDirectory == "/path/that/does/not")
    }

    @Test func emptyFileMount() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let emptyFile = tempDir.appendingPathComponent("empty-\(#function).txt")

        try "".write(to: emptyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: emptyFile) }

        let mount = Mount.share(
            source: emptyFile.path,
            destination: "/app/empty.txt"
        )

        #expect(mount.isFile == true)
        #expect(mount.filename.hasPrefix("empty-"))
        #expect(mount.parentDirectory == tempDir.path)
    }

    @Test func specialCharactersInFilename() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let specialFile = tempDir.appendingPathComponent("file with spaces & symbols!@#-\(#function).txt")

        try "special content".write(to: specialFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: specialFile) }

        let mount = Mount.share(
            source: specialFile.path,
            destination: "/app/special.txt"
        )

        #expect(mount.isFile == true)
        #expect(mount.filename.hasPrefix("file with spaces & symbols!@#-"))
        #expect(mount.parentDirectory == tempDir.path)

        let allocator = Character.blockDeviceTagAllocator()
        let attached = try AttachedFilesystem(mount: mount, allocator: allocator)
        #expect(attached.isFile == true)
    }

    @Test func hiddenFileMount() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let hiddenFile = tempDir.appendingPathComponent(".hidden-\(#function)")

        try "hidden content".write(to: hiddenFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: hiddenFile) }

        let mount = Mount.share(
            source: hiddenFile.path,
            destination: "/app/.config"
        )

        #expect(mount.isFile == true)
        #expect(mount.filename.hasPrefix(".hidden-"))
        #expect(mount.parentDirectory == tempDir.path)
    }

    @Test func readOnlyFileMount() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let readOnlyFile = tempDir.appendingPathComponent("readonly-\(#function).txt")

        try "readonly content".write(to: readOnlyFile, atomically: true, encoding: .utf8)
        defer {
            // Remove read-only attribute before deletion
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnlyFile.path)
            try? FileManager.default.removeItem(at: readOnlyFile)
        }

        // Make file read-only
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyFile.path)

        let mount = Mount.share(
            source: readOnlyFile.path,
            destination: "/app/readonly.txt"
        )

        #expect(mount.isFile == true)
        #expect(mount.filename.hasPrefix("readonly-"))

        let allocator = Character.blockDeviceTagAllocator()
        let attached = try AttachedFilesystem(mount: mount, allocator: allocator)
        #expect(attached.isFile == true)
    }

    @Test func hardlinkIsolation() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("isolation-test-\(#function).txt")
        let originalContent = "hardlink test content"

        try originalContent.write(to: testFile, atomically: true, encoding: .utf8)

        let mount = Mount.share(
            source: testFile.path,
            destination: "/app/config-\(#function).txt"
        )

        // Create hardlink isolation
        let isolatedDir = try mount.createIsolatedFileShare()

        // Cleanup in reverse order to prevent race conditions
        defer { try? FileManager.default.removeItem(at: testFile) }
        defer { Mount.releaseIsolatedFileShare(source: testFile.path, destination: "/app/config-\(#function).txt") }

        // Verify isolated directory contains only the target file
        let isolatedContents = try FileManager.default.contentsOfDirectory(atPath: isolatedDir)
        #expect(isolatedContents.count == 1)
        #expect(isolatedContents.first == "config-hardlinkIsolation().txt")

        // Verify hardlinked file has same content
        let isolatedFile = URL(fileURLWithPath: isolatedDir).appendingPathComponent("config-hardlinkIsolation().txt")
        let isolatedContent = try String(contentsOf: isolatedFile, encoding: .utf8)
        #expect(isolatedContent == originalContent)

        // Verify calling createIsolatedFileShare again returns the same directory (deterministic)
        let isolatedDir2 = try mount.createIsolatedFileShare()
        #expect(isolatedDir == isolatedDir2)

        // Verify the directory still contains the same file content
        let isolatedFile2 = URL(fileURLWithPath: isolatedDir2).appendingPathComponent("config-hardlinkIsolation().txt")
        let isolatedContent2 = try String(contentsOf: isolatedFile2, encoding: .utf8)
        #expect(isolatedContent2 == originalContent)
    }

    @Test func fileMountDestinationAdjustment() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("dest-test-\(#function).txt")

        try "destination test".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let mount = Mount.share(
            source: testFile.path,
            destination: "/app/subdir/config-\(#function).txt"
        )

        let allocator = Character.blockDeviceTagAllocator()
        let attached = try AttachedFilesystem(mount: mount, allocator: allocator)

        // For file mounts, destination should be adjusted to parent directory
        #expect(attached.destination == "/app/subdir")
        #expect(attached.isFile == true)

        // Clean up hardlink isolation directory (should return same deterministic directory)
        _ = try mount.createIsolatedFileShare()
        Mount.releaseIsolatedFileShare(source: testFile.path, destination: "/app/subdir/config-\(#function).txt")
    }

    @Test func rejectsSymlinks() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("symlink-source-\(#function).txt")
        let symlinkFile = tempDir.appendingPathComponent("symlink-test-\(#function).txt")

        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: testFile)
        defer { try? FileManager.default.removeItem(at: symlinkFile) }

        let mount = Mount.share(source: symlinkFile.path, destination: "/app/config-\(#function).txt")

        #expect(throws: ContainerizationError.self) {
            try mount.createIsolatedFileShare()
        }
    }

    @Test func rejectsNonExistentFiles() throws {
        let mount = Mount.share(source: "/nonexistent/file.txt", destination: "/app/config-\(#function).txt")

        #expect(throws: ContainerizationError.self) {
            try mount.createIsolatedFileShare()
        }
    }

    @Test func rejectsDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent("test-directory-\(#function)")

        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let mount = Mount.share(source: testDir.path, destination: "/app/config-\(#function).txt")

        #expect(throws: ContainerizationError.self) {
            try mount.createIsolatedFileShare()
        }
    }

    @Test func registersForCleanup() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("cleanup-test-\(#function).txt")

        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let mount = Mount.share(source: testFile.path, destination: "/app/config-\(#function).txt")
        let isolatedDir = try mount.createIsolatedFileShare()

        // Verify directory was created
        #expect(FileManager.default.fileExists(atPath: isolatedDir))

        // Test cleanup functionality
        VZVirtualMachineInstance.cleanupTempDirectories()

        // Directory should be removed after cleanup
        #expect(!FileManager.default.fileExists(atPath: isolatedDir))
    }
    #endif
}
