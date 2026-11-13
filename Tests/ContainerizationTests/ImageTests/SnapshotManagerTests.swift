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
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import SystemPackage
import Testing

@testable import Containerization
@testable import ContainerizationEXT4

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite
struct SnapshotManagerTests {
    /// The linux/arm64 manifest in `scratch.tar`. Its one layer holds `/file`.
    private static let manifest = "872d74070f985083ac362527084460ff5a21815dfabd6e8de8baf677206340ee"
    /// The linux/amd64 manifest in `scratch.tar`, with the same layer.
    private static let amd64Manifest = "3f2b0792ca7c9418ca2483c03bef2e3d3ea23205d0add5bd5cc55cdbc993027e"
    /// The layer blob of both manifests.
    private static let layer = "530a471644602a73c05568aa468506f7a630f6c0a0e43e9052f1f4469d8241cf"
    private static let platform = Platform(arch: "arm64", os: "linux")
    /// Small, so the tests do not create 512 GiB sparse files.
    private static let capacity: UInt64 = 16.mib()

    private struct Fixture {
        let root: URL
        // ContainerizationOCI also declares an `Image`.
        let image: Containerization.Image
        let snapshots: SnapshotManager

        var entry: String { self.file("\(SnapshotManagerTests.manifest).ext4") }
        var lock: String { self.file("\(SnapshotManagerTests.manifest).lock") }

        func file(_ name: String) -> String {
            self.snapshots.path.appendingPathComponent(name).absolutePath()
        }

        func names() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: self.snapshots.path.absolutePath())
        }
    }

    /// Records which calls got unpack progress. Only a call that unpacks gets any.
    private actor ProgressRecorder {
        private(set) var callers: Set<String> = []

        func record(_ caller: String) {
            self.callers.insert(caller)
        }
    }

    /// A new image store that holds the image from `scratch.tar`, and an empty snapshot directory.
    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.uniqueTemporaryDirectory(create: true)
        do {
            let layout = root.appendingPathComponent("layout")
            try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
            let tar = try #require(Foundation.Bundle.module.url(forResource: "scratch", withExtension: "tar"))
            let reader = try ArchiveReader(format: .pax, filter: .none, file: tar)
            let rejected = try reader.extractContents(to: layout)
            #expect(rejected.isEmpty)

            let store = try ImageStore(path: root.appendingPathComponent("store"))
            let images = try await store.load(from: layout)
            let image = try #require(images.first)
            let snapshots = try SnapshotManager(path: root.appendingPathComponent("snapshots"), capacityInBytes: Self.capacity)
            return Fixture(root: root, image: image, snapshots: snapshots)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test func unpackNamesTheSnapshotByItsManifestDigest() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        #expect(try await f.snapshots.get(f.image, for: Self.platform) == nil)

        let snapshot = try await f.snapshots.unpack(f.image, for: Self.platform)
        #expect(snapshot.absolutePath() == f.entry)
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(f.entry))
        #expect(reader.exists(FilePath("/file")))

        let found = try #require(try await f.snapshots.get(f.image, for: Self.platform))
        #expect(found.absolutePath() == f.entry)
    }

    @Test func unpackReusesTheSnapshot() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let first = try await f.snapshots.unpack(f.image, for: Self.platform)
        let inode = try Self.inode(first.absolutePath())

        // A second manager on the same directory stands in for another process.
        let other = try SnapshotManager(path: f.snapshots.path, capacityInBytes: Self.capacity)
        let second = try await other.unpack(f.image, for: Self.platform)
        #expect(second.absolutePath() == first.absolutePath())
        #expect(try Self.inode(second.absolutePath()) == inode)
    }

    @Test func concurrentUnpacksUnpackOnce() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let recorder = ProgressRecorder()
        let other = try SnapshotManager(path: f.snapshots.path, capacityInBytes: Self.capacity)
        async let first = f.snapshots.unpack(f.image, for: Self.platform) { _ in await recorder.record("first") }
        async let second = other.unpack(f.image, for: Self.platform) { _ in await recorder.record("second") }
        let (a, b) = try await (first, second)

        #expect(a.absolutePath() == f.entry)
        #expect(b.absolutePath() == f.entry)
        // The call that waits for the lock finds the finished snapshot and does not unpack.
        #expect(await recorder.callers.count == 1)
        #expect(try !f.names().contains { $0.hasSuffix(".tmp") })
    }

    @Test func unpackWaitsForTheLockAndUsesTheFinishedSnapshot() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let held = try Self.lock(f.lock)
        let snapshots = f.snapshots
        let image = f.image
        let waiter = Task { try await snapshots.unpack(image, for: Self.platform) }

        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: f.entry))

        // Stand in for another process that finishes the snapshot while it holds the lock.
        let marker = Data("finished by another process".utf8)
        try marker.write(to: URL(fileURLWithPath: f.entry))
        Self.unlock(held)

        let snapshot = try await waiter.value
        #expect(snapshot.absolutePath() == f.entry)
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.entry)) == marker)
    }

    @Test func cancellingAWaitingUnpackThrowsCancellationError() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let held = try Self.lock(f.lock)
        defer { Self.unlock(held) }
        let snapshots = f.snapshots
        let image = f.image
        let waiter = Task { try await snapshots.unpack(image, for: Self.platform) }

        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(!FileManager.default.fileExists(atPath: f.entry))
    }

    @Test func cancellingDuringTheUnpackLeavesNoSnapshot() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // The unpacker reports progress after it creates its temporary file, and checks for
        // cancellation before it reads each layer.
        let snapshots = f.snapshots
        let image = f.image
        let unpack = Task {
            try await snapshots.unpack(image, for: Self.platform) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) {
            try await unpack.value
        }
        #expect(!FileManager.default.fileExists(atPath: f.entry))
        #expect(try !f.names().contains { $0.hasSuffix(".tmp") })

        let fd = try #require(Self.tryLock(f.lock))
        Self.unlock(fd)
    }

    @Test func failedUnpackLeavesNoSnapshotAndReleasesTheLock() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // Without its layer blob, the unpack fails after it has created its temporary file.
        let blob = f.root.appendingPathComponent("store/content/blobs/sha256/\(Self.layer)")
        try FileManager.default.removeItem(at: blob)

        await #expect(throws: (any Error).self) {
            try await f.snapshots.unpack(f.image, for: Self.platform)
        }
        #expect(try !f.names().contains { $0.hasSuffix(".ext4") || $0.hasSuffix(".tmp") })

        let fd = try #require(Self.tryLock(f.lock))
        Self.unlock(fd)
    }

    @Test func leftoverTemporaryFileIsNeverUsedAndIsRemovedByTheNextUnpack() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // A fill that died leaves its temporary file behind.
        let leftover = f.file(".\(Self.manifest).\(UUID().uuidString).tmp")
        try Data("partial".utf8).write(to: URL(fileURLWithPath: leftover))
        #expect(try await f.snapshots.get(f.image, for: Self.platform) == nil)

        let snapshot = try await f.snapshots.unpack(f.image, for: Self.platform)
        #expect(!FileManager.default.fileExists(atPath: leftover))
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(snapshot.absolutePath()))
        #expect(reader.exists(FilePath("/file")))
    }

    @Test func cloneIsAnIndependentCopy() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let destination = f.root.appendingPathComponent("rootfs.ext4")
        let clone = try await f.snapshots.clone(f.image, for: Self.platform, to: destination)
        #expect(clone.source == destination.absolutePath())
        #expect(!clone.options.contains("ro"))
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(clone.source))
        #expect(reader.exists(FilePath("/file")))

        let before = try Self.prefix(of: f.entry)
        try Self.overwritePrefix(of: clone.source)
        #expect(try Self.prefix(of: f.entry) == before)
        #expect(try Self.inode(clone.source) != Self.inode(f.entry))
    }

    @Test func cloneToAnExistingPathThrowsExists() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let destination = f.root.appendingPathComponent("rootfs.ext4")
        try Data().write(to: destination)
        do {
            _ = try await f.snapshots.clone(f.image, for: Self.platform, to: destination)
            Issue.record("expected an .exists error")
        } catch let error as ContainerizationError {
            #expect(error.code == .exists)
        }
    }

    @Test func deleteKeepingNothingRemovesTheSnapshot() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        try await f.snapshots.unpack(f.image, for: Self.platform)
        let result = try await f.snapshots.delete(keeping: [])
        #expect(result.deleted == ["sha256:\(Self.manifest)"])
        #expect(result.freed > 0)
        #expect(!FileManager.default.fileExists(atPath: f.entry))
    }

    @Test func deleteRemovesOnlyUnreferencedSnapshots() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // Both platforms of the kept image, and a snapshot whose image is gone.
        try await f.snapshots.unpack(f.image, for: Self.platform)
        try await f.snapshots.unpack(f.image, for: Platform(arch: "amd64", os: "linux"))
        let gone = String(repeating: "0", count: 64)
        try Data("gone".utf8).write(to: URL(fileURLWithPath: f.file("\(gone).ext4")))

        let result = try await f.snapshots.delete(keeping: [f.image])
        #expect(result.deleted == ["sha256:\(gone)"])
        #expect(FileManager.default.fileExists(atPath: f.entry))
        #expect(FileManager.default.fileExists(atPath: f.file("\(Self.amd64Manifest).ext4")))
        #expect(!FileManager.default.fileExists(atPath: f.file("\(gone).ext4")))
    }

    @Test func deleteSkipsASnapshotWhoseLockIsHeld() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        try await f.snapshots.unpack(f.image, for: Self.platform)
        let liveFill = f.file(".\(Self.manifest).\(UUID().uuidString).tmp")
        try Data("being written".utf8).write(to: URL(fileURLWithPath: liveFill))
        let held = try Self.lock(f.lock)
        let skipped = try await f.snapshots.delete(keeping: [])
        #expect(skipped.deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.entry))
        #expect(FileManager.default.fileExists(atPath: liveFill))

        Self.unlock(held)
        let removed = try await f.snapshots.delete(keeping: [])
        #expect(removed.deleted == ["sha256:\(Self.manifest)"])
        #expect(!FileManager.default.fileExists(atPath: liveFill))
    }

    @Test func deleteSkipsASnapshotWhileItIsBeingCloned() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        try await f.snapshots.unpack(f.image, for: Self.platform)
        let cloning = try Self.lock(f.lock, shared: true)
        defer { Self.unlock(cloning) }

        let result = try await f.snapshots.delete(keeping: [])
        #expect(result.deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.entry))
    }

    @Test func deleteChangesNothingWhenAnImageIndexIsMissing() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        try await f.snapshots.unpack(f.image, for: Self.platform)
        let index = try ParsedDigest(parsing: f.image.digest).encoded
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("store/content/blobs/sha256/\(index)"))

        await #expect(throws: (any Error).self) {
            try await f.snapshots.delete(keeping: [f.image])
        }
        #expect(FileManager.default.fileExists(atPath: f.entry))
    }

    @Test func cloneUnpacksAgainAfterTheSnapshotIsDeleted() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        try await f.snapshots.unpack(f.image, for: Self.platform)
        try await f.snapshots.delete(keeping: [])
        #expect(!FileManager.default.fileExists(atPath: f.entry))

        let clone = try await f.snapshots.clone(f.image, for: Self.platform, to: f.root.appendingPathComponent("rootfs.ext4"))
        #expect(FileManager.default.fileExists(atPath: f.entry))
        #expect(try EXT4.EXT4Reader(blockDevice: FilePath(clone.source)).exists(FilePath("/file")))
    }

    @Test func deleteRemovesLeftoverTemporaryFilesAndKeepsOtherFiles() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        try await f.snapshots.unpack(f.image, for: Self.platform)
        let leftover = f.file(".\(Self.manifest).\(UUID().uuidString).tmp")
        try Data("partial".utf8).write(to: URL(fileURLWithPath: leftover))
        let other = f.file("notes.txt")
        try Data("not a snapshot".utf8).write(to: URL(fileURLWithPath: other))

        let result = try await f.snapshots.delete(keeping: [f.image])
        #expect(result.deleted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: leftover))
        #expect(FileManager.default.fileExists(atPath: other))
        #expect(FileManager.default.fileExists(atPath: f.entry))
    }

    // MARK: - Helpers

    /// Takes the lock the way another process would: a separate `open(2)` and `flock(2)`.
    private static func lock(_ path: String, shared: Bool = false) throws -> Int32 {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(fd, shared ? LOCK_SH : LOCK_EX) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    private static func tryLock(_ path: String) -> Int32? {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return nil
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func unlock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    private static func inode(_ path: String) throws -> UInt64 {
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt64(st.st_ino)
    }

    /// The first block of a file. Snapshots are large sparse files, so the tests never read a whole one.
    private static func prefix(of path: String) throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw POSIXError(.ENOENT)
        }
        defer { try? handle.close() }
        return try handle.read(upToCount: 4096) ?? Data()
    }

    private static func overwritePrefix(of path: String) throws {
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw POSIXError(.ENOENT)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 4096))
    }
}
