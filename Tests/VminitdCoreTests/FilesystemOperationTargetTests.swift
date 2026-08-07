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

#if os(Linux)

import Foundation
import Glibc
import Testing

@testable import VminitdCore

private let mountNamespaceTestEnabled =
    ProcessInfo.processInfo.environment["CONTAINERIZATION_TEST_MOUNT_NAMESPACE"] == "1"

struct FilesystemOperationTargetTests {
    @Test func opensPathRelativeToContainerRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let target = root.appending(path: "mnt/reclaim-data")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rootDescriptor = Glibc.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(rootDescriptor >= 0)
        defer { _ = Glibc.close(rootDescriptor) }

        let targetDescriptor = try FilesystemOperationTarget.open(
            rootDescriptor: rootDescriptor,
            path: "/mnt/reclaim-data"
        )
        defer { _ = Glibc.close(targetDescriptor) }

        var expected = Glibc.stat()
        var actual = Glibc.stat()
        #expect(Glibc.lstat(target.path, &expected) == 0)
        #expect(Glibc.fstat(targetDescriptor, &actual) == 0)
        #expect(actual.st_dev == expected.st_dev)
        #expect(actual.st_ino == expected.st_ino)
    }

    @Test func containsAbsoluteSymlinksWithinContainerRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Glibc.symlink("/", root.appending(path: "escape").path) == 0)

        let rootDescriptor = Glibc.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(rootDescriptor >= 0)
        defer { _ = Glibc.close(rootDescriptor) }

        #expect(throws: POSIXError.self) {
            _ = try FilesystemOperationTarget.open(
                rootDescriptor: rootDescriptor,
                path: "/escape/etc"
            )
        }
    }

    @Test func rejectsProcMagicLinks() throws {
        let rootDescriptor = Glibc.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(rootDescriptor >= 0)
        defer { _ = Glibc.close(rootDescriptor) }

        #expect(throws: POSIXError.self) {
            _ = try FilesystemOperationTarget.open(
                rootDescriptor: rootDescriptor,
                path: "/proc/self/root"
            )
        }
    }
}

struct ProcessRootTests {
    @Test(.enabled(if: mountNamespaceTestEnabled))
    func opensMountFromTargetProcessNamespace() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source")
        let target = root.appending(path: "target")
        let ready = root.appending(path: "ready")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unshare")
        process.arguments = [
            "--mount",
            "--",
            "/bin/sh",
            "-c",
            "mount --make-rprivate / && mount --bind \"$1\" \"$2\" && touch \"$3\" && exec sleep 5",
            "mount-namespace-test",
            source.path,
            target.path,
            ready.path,
        ]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let deadline = Date.now.addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date.now < deadline {
            usleep(10_000)
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))

        let processRoot = try ProcessRoot(processID: process.processIdentifier)
        let rootDescriptor = try processRoot.openRoot()
        defer { _ = Glibc.close(rootDescriptor) }
        let targetDescriptor = try FilesystemOperationTarget.open(
            rootDescriptor: rootDescriptor,
            path: target.path
        )
        defer { _ = Glibc.close(targetDescriptor) }

        var sourceInfo = Glibc.stat()
        var parentTargetInfo = Glibc.stat()
        var namespacedTargetInfo = Glibc.stat()
        #expect(Glibc.lstat(source.path, &sourceInfo) == 0)
        #expect(Glibc.lstat(target.path, &parentTargetInfo) == 0)
        #expect(Glibc.fstat(targetDescriptor, &namespacedTargetInfo) == 0)
        #expect(namespacedTargetInfo.st_dev == sourceInfo.st_dev)
        #expect(namespacedTargetInfo.st_ino == sourceInfo.st_ino)
        #expect(namespacedTargetInfo.st_ino != parentTargetInfo.st_ino)
    }

    @Test func opensRunningProcessRoot() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["1"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let processRoot = try ProcessRoot(processID: process.processIdentifier)
        let descriptor = try processRoot.openRoot()
        defer { _ = Glibc.close(descriptor) }

        var expected = Glibc.stat()
        var actual = Glibc.stat()
        #expect(Glibc.lstat("/", &expected) == 0)
        #expect(Glibc.fstat(descriptor, &actual) == 0)
        #expect(actual.st_dev == expected.st_dev)
        #expect(actual.st_ino == expected.st_ino)
    }

    @Test func doesNotRetargetAfterProcessExit() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["1"]
        try process.run()

        let processRoot = try ProcessRoot(processID: process.processIdentifier)
        process.terminate()
        process.waitUntilExit()

        #expect(throws: POSIXError.self) {
            _ = try processRoot.openRoot()
        }
    }
}

#endif
