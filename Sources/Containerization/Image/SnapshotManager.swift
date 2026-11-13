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
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Keeps each image's root filesystem unpacked once, as an ext4 snapshot, so containers can
/// start from a copy-on-write clone instead of unpacking the image again.
///
/// Use ``clone(_:for:to:progress:)`` to get a container's root filesystem. The first call for
/// an image unpacks it, and later calls clone the existing snapshot. Each container needs its
/// own clone, because `LinuxContainer` attaches its root filesystem writable.
///
/// Processes that run as the same user can share one `path`. A lock per snapshot lets one process
/// unpack an image while the others wait for it, with no time limit; cancel the task to stop
/// waiting. A snapshot appears through one `rename(2)` of a complete, synced file, so no process
/// reads a partial snapshot. The caller decides when to delete snapshots, with ``delete(keeping:)``.
///
/// On macOS, clones use `clonefile(2)`, so `path` must be on the same APFS volume as the clone
/// destinations, for example in a `snapshots` directory under the image store's `path`.
///
/// Files in `path`, where `<hex>` is the hex digest of the image's platform manifest:
/// - `<hex>.ext4`: a complete snapshot.
/// - `<hex>.lock`: the lock for that snapshot. It stays after the snapshot is deleted.
/// - `.<hex>.<uuid>.tmp`: a snapshot that is being written.
public struct SnapshotManager: Sendable {
    /// The directory that holds the snapshots.
    public let path: URL

    private let capacityInBytes: UInt64
    private let logger: Logger?

    /// Creates a manager for the snapshots in `path`, and creates the directory if needed.
    ///
    /// - Parameters:
    ///   - path: The directory that holds the snapshots.
    ///   - capacityInBytes: The minimum capacity of each new snapshot's filesystem. A snapshot
    ///     is a sparse file that grows to fit the image, so a large capacity costs little disk.
    ///     A smaller capacity also limits the largest image that can be unpacked. A snapshot keeps the
    ///     capacity it was unpacked with, even if a later manager uses a different value.
    ///   - logger: Optional logger.
    /// - Throws: An error if the directory cannot be created.
    public init(path: URL, capacityInBytes: UInt64 = 512.gib(), logger: Logger? = nil) throws {
        // EXT4.Formatter sizes its group descriptor table from the initial capacity: up to 16 GiB
        // caps a snapshot at 512 GiB, and 512 GiB allows 16 TiB. The file stays sparse either way.
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        self.path = path
        self.capacityInBytes = capacityInBytes
        self.logger = logger
    }

    /// Returns the path of the image's snapshot for `platform`, and unpacks the image first
    /// if it has none.
    ///
    /// Concurrent calls for the same snapshot unpack it once, in one process or across
    /// processes. The other calls wait and then return the finished snapshot. A waiting call
    /// throws `CancellationError` if its task is cancelled.
    ///
    /// The file is shared, and nothing may write to it. To give it to a container, clone it
    /// with ``clone(_:for:to:progress:)``. The snapshot stays until ``delete(keeping:)`` removes it.
    ///
    /// Only the call that unpacks receives `progress` events. A `progress` handler also makes the
    /// unpacker read every layer a second time, to compute totals.
    ///
    /// - Throws: A `ContainerizationError` with code `.invalidArgument` if `image` has no manifest
    ///   for `platform`.
    @discardableResult
    public func unpack(_ image: Image, for platform: Platform = .current, progress: ProgressHandler? = nil) async throws -> URL {
        let digest = try await Self.manifestDigest(of: image, for: platform)
        if let snapshot = self.existing(digest) {
            return snapshot
        }

        let lock = try await SnapshotLock.acquire(at: self.lockPath(digest))
        defer { lock.release() }

        // Another process can finish the snapshot while this one waits for the lock.
        if let snapshot = self.existing(digest) {
            return snapshot
        }

        // Left by a fill that died. No live fill of this snapshot runs while the lock is held.
        try self.removeTemporaryFiles(digest)

        let start = ContinuousClock.now
        let entry = self.entryURL(digest)
        let temporary = self.path.appendingPathComponent(".\(digest.encoded).\(UUID().uuidString).tmp")
        do {
            let unpacker = EXT4Unpacker(capacityInBytes: self.capacityInBytes)
            _ = try await unpacker.unpack(image, for: platform, at: temporary, progress: progress)
            try Self.flush(temporary.absolutePath())
            try Self.publish(temporary.absolutePath(), as: entry.absolutePath())
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        self.logger?.info("unpacked snapshot \(digest) of \(image.reference) in \(ContinuousClock.now - start)")
        return entry
    }

    /// Returns the path of the image's existing snapshot for `platform`, or `nil` if it has
    /// none. It never unpacks the image.
    ///
    /// - Throws: A `ContainerizationError` with code `.invalidArgument` if `image` has no manifest
    ///   for `platform`.
    public func get(_ image: Image, for platform: Platform = .current) async throws -> URL? {
        self.existing(try await Self.manifestDigest(of: image, for: platform))
    }

    /// Clones the image's snapshot for `platform` to `destination`, and unpacks the image first
    /// if it has none.
    ///
    /// The clone belongs to the caller, and a container can attach it writable. On macOS the
    /// clone uses `clonefile(2)` and copies no data. If a copy-on-write clone is not possible,
    /// for example because `destination` is on another volume, the call throws instead of
    /// copying the data. On Linux the clone uses `Mount.clone(to:)`, which copies the data when
    /// the filesystem cannot clone it, and the copy is neither atomic nor exclusive.
    ///
    /// ``delete(keeping:)`` skips the snapshot while it is being cloned.
    ///
    /// - Throws: A `ContainerizationError` with code `.exists` if `destination` exists, and
    ///   `.unsupported` if the clone cannot be copy-on-write on macOS.
    public func clone(
        _ image: Image,
        for platform: Platform = .current,
        to destination: URL,
        progress: ProgressHandler? = nil
    ) async throws -> Mount {
        let target = destination.absolutePath()
        guard !FileManager.default.fileExists(atPath: target) else {
            throw ContainerizationError(.exists, message: "clone destination \(target) already exists")
        }
        let digest = try await Self.manifestDigest(of: image, for: platform)

        // Holders of the shared lock do not exclude each other. A fill and a delete need the
        // exclusive lock, so the snapshot cannot change while this call clones it.
        var lock = try await SnapshotLock.acquire(at: self.lockPath(digest), shared: true)
        while self.existing(digest) == nil {
            lock.release()
            try await self.unpack(image, for: platform, progress: progress)
            lock = try await SnapshotLock.acquire(at: self.lockPath(digest), shared: true)
        }
        defer { lock.release() }

        let snapshot = self.entryURL(digest).absolutePath()
        #if os(macOS)
        guard clonefile(snapshot, target, 0) == 0 else {
            let code = errno
            throw Self.cloneError(code, source: snapshot, destination: target)
        }
        #else
        do {
            _ = try Self.mount(snapshot).clone(to: target)
        } catch {
            try? FileManager.default.removeItem(atPath: target)
            throw error
        }
        #endif
        return Self.mount(target)
    }

    /// Deletes every snapshot that none of `images` references, for any platform.
    ///
    /// It also removes temporary files left by fills that died. It skips a snapshot while a fill,
    /// a clone, or another delete uses it, and it never waits. A container cloned from a deleted
    /// snapshot keeps working, because it has its own copy.
    ///
    /// `images` must include every image that can still start containers. The call throws, and
    /// deletes nothing more, if it cannot read the index of one of them.
    ///
    /// - Returns: The digests of the deleted snapshots, as `sha256:<hex>`, and the allocated size
    ///   of the files it removed. Blocks that a removed snapshot shares with clones stay in use
    ///   until the clones are deleted too.
    @discardableResult
    public func delete(keeping images: [Image]) async throws -> (deleted: [String], freed: UInt64) {
        var keep: Set<ParsedDigest> = []
        for image in images {
            // A partial keep set would delete snapshots that are still in use, so an image
            // whose index cannot be read fails the call.
            let index = try await image.index()
            for manifest in index.manifests {
                // A malformed digest cannot name a snapshot, so it has nothing to keep.
                if let digest = try? ParsedDigest(parsing: manifest.digest) {
                    keep.insert(digest)
                }
            }
        }

        var candidates: Set<ParsedDigest> = []
        var withTemporaries: Set<ParsedDigest> = []
        for name in try FileManager.default.contentsOfDirectory(atPath: self.path.absolutePath()) {
            if let digest = Self.snapshotDigest(in: name) {
                candidates.insert(digest)
            } else if let digest = Self.temporaryDigest(in: name) {
                candidates.insert(digest)
                withTemporaries.insert(digest)
            }
        }

        var deleted: [String] = []
        var freed: UInt64 = 0
        for digest in candidates.sorted(by: { $0.encoded < $1.encoded }) {
            guard let lock = try SnapshotLock.tryAcquire(at: self.lockPath(digest)) else {
                continue
            }
            defer { lock.release() }

            if withTemporaries.contains(digest) {
                freed += try self.removeTemporaryFiles(digest)
            }
            if !keep.contains(digest), let snapshot = self.existing(digest) {
                freed += Self.allocatedSize(snapshot.absolutePath())
                try FileManager.default.removeItem(at: snapshot)
                deleted.append(digest.description)
            }
        }
        return (deleted, freed)
    }

    private func entryURL(_ digest: ParsedDigest) -> URL {
        self.path.appendingPathComponent("\(digest.encoded).ext4")
    }

    private func lockPath(_ digest: ParsedDigest) -> String {
        self.path.appendingPathComponent("\(digest.encoded).lock").absolutePath()
    }

    private func existing(_ digest: ParsedDigest) -> URL? {
        let snapshot = self.entryURL(digest)
        return FileManager.default.fileExists(atPath: snapshot.absolutePath()) ? snapshot : nil
    }

    @discardableResult
    private func removeTemporaryFiles(_ digest: ParsedDigest) throws -> UInt64 {
        var freed: UInt64 = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: self.path.absolutePath()) where Self.temporaryDigest(in: name) == digest {
            let file = self.path.appendingPathComponent(name)
            freed += Self.allocatedSize(file.absolutePath())
            try FileManager.default.removeItem(at: file)
        }
        return freed
    }

    private static func manifestDigest(of image: Image, for platform: Platform) async throws -> ParsedDigest {
        let descriptor = try await image.descriptor(for: platform)
        return try ParsedDigest(parsing: descriptor.digest)
    }

    private static func mount(_ source: String) -> Mount {
        .block(format: "ext4", source: source, destination: "/")
    }

    /// The digest in a snapshot file name of the form `<hex>.ext4`.
    private static func snapshotDigest(in name: String) -> ParsedDigest? {
        guard name.hasSuffix(".ext4") else {
            return nil
        }
        return try? ParsedDigest(parsing: "sha256:\(name.dropLast(".ext4".count))")
    }

    /// The digest in a temporary file name of the form `.<hex>.<uuid>.tmp`.
    private static func temporaryDigest(in name: String) -> ParsedDigest? {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else {
            return nil
        }
        let middle = name.dropFirst().dropLast(".tmp".count)
        guard let dot = middle.firstIndex(of: ".") else {
            return nil
        }
        return try? ParsedDigest(parsing: "sha256:\(middle[..<dot])")
    }

    /// Writes the file's data to stable storage. Without this, a crash after the rename
    /// could leave a snapshot whose data never reached the disk.
    private static func flush(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            throw posixError("open \(path)", code)
        }
        defer { close(fd) }
        #if os(macOS)
        // On macOS, fsync(2) leaves data in the drive's cache and F_FULLFSYNC does not.
        // Fall back to fsync(2) only where F_FULLFSYNC is not supported. Any other error
        // means the data may not be on disk.
        if fcntl(fd, F_FULLFSYNC) == 0 {
            return
        }
        let code = errno
        guard code == ENOTSUP || code == ENOTTY || code == EINVAL || code == ENODEV else {
            throw posixError("F_FULLFSYNC \(path)", code)
        }
        #endif
        guard fsync(fd) == 0 else {
            let code = errno
            throw posixError("fsync \(path)", code)
        }
    }

    /// Moves a complete snapshot into place. rename(2) replaces any existing file atomically,
    /// so a reader sees either no snapshot or a complete one.
    private static func publish(_ temporary: String, as entry: String) throws {
        guard rename(temporary, entry) == 0 else {
            let code = errno
            throw posixError("rename \(temporary) to \(entry)", code)
        }
    }

    private static func allocatedSize(_ path: String) -> UInt64 {
        var st = stat()
        guard stat(path, &st) == 0 else {
            return 0
        }
        return UInt64(st.st_blocks) * 512
    }

    #if os(macOS)
    private static func cloneError(_ code: Int32, source: String, destination: String) -> ContainerizationError {
        let cause = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        switch code {
        case ENOTSUP, EXDEV:
            return ContainerizationError(
                .unsupported,
                message: "cannot clone snapshot \(source) to \(destination): a copy-on-write clone needs both on the same APFS volume",
                cause: cause
            )
        case EEXIST:
            return ContainerizationError(.exists, message: "clone destination \(destination) already exists", cause: cause)
        case ENOENT:
            return ContainerizationError(.notFound, message: "cannot clone snapshot \(source) to \(destination): \(cause)", cause: cause)
        default:
            return ContainerizationError(.internalError, message: "cannot clone snapshot \(source) to \(destination): \(cause)", cause: cause)
        }
    }
    #endif
}

private func posixError(_ operation: String, _ code: Int32) -> ContainerizationError {
    let cause = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    return ContainerizationError(.internalError, message: "\(operation) failed: \(cause)", cause: cause)
}

/// An exclusive `flock(2)` on a snapshot's lock file, held until `release()`.
private struct SnapshotLock {
    private let fd: Int32

    /// Waits for the lock. It polls with `LOCK_NB` instead of blocking in `flock(2)`, so a wait
    /// that can last as long as an image unpack does not hold a thread and stays cancellable.
    /// Holders of a shared lock do not exclude each other, and an exclusive holder excludes all.
    static func acquire(at path: String, shared: Bool = false) async throws -> SnapshotLock {
        let fd = try openLockFile(path)
        let operation = (shared ? LOCK_SH : LOCK_EX) | LOCK_NB
        var delay: Duration = .milliseconds(10)
        while flock(fd, operation) != 0 {
            let code = errno
            guard code == EWOULDBLOCK else {
                close(fd)
                throw posixError("lock \(path)", code)
            }
            do {
                try await Task.sleep(for: delay)
            } catch {
                close(fd)
                throw error
            }
            delay = min(delay * 2, .milliseconds(100))
        }
        return SnapshotLock(fd: fd)
    }

    /// Takes the exclusive lock if it is free. Returns `nil` if another holder has it.
    static func tryAcquire(at path: String) throws -> SnapshotLock? {
        let fd = try openLockFile(path)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            guard code == EWOULDBLOCK else {
                throw posixError("lock \(path)", code)
            }
            return nil
        }
        return SnapshotLock(fd: fd)
    }

    func release() {
        _ = flock(self.fd, LOCK_UN)
        close(self.fd)
    }

    private static func openLockFile(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let code = errno
            throw posixError("open \(path)", code)
        }
        return fd
    }
}
