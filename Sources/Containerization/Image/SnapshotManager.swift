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
import Crypto
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
/// Call ``unpack(_:for:progress:)`` to make sure an image has a snapshot, then
/// ``clone(_:for:to:)`` to give a container its own copy. Each container needs its own clone,
/// because `LinuxContainer` attaches its root filesystem writable.
///
/// A snapshot is keyed by the chain ID of the image's layers, so images that differ only in
/// their config share one. ``key(of:for:)`` returns the key.
///
/// Processes that run as the same user can share one `path`. A lock per snapshot lets one process
/// unpack an image while the others wait for it, with no time limit; cancel the task to stop
/// waiting. A snapshot appears through one `rename(2)` of a complete, synced file, so no process
/// reads a partial snapshot. The caller decides when to delete snapshots, with ``delete(keeping:)``.
///
/// On macOS, clones use `clonefile(2)`, so `path` must be on the same APFS volume as the clone
/// destinations, for example in a `snapshots` directory under the image store's `path`.
///
/// Files in `path`, where `<hex>` is the hex digest of a snapshot's key:
/// - `<hex>.ext4`: a complete snapshot.
/// - `<hex>.lock`: the lock for that snapshot. It stays after the snapshot is deleted.
/// - `.<hex>.<uuid>.tmp`: a snapshot that is being written.
public struct SnapshotManager: Sendable {
    /// The directory that holds the snapshots.
    public let path: URL

    /// The minimum capacity of new snapshots. Each one grows to fit its image.
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
    /// with ``clone(_:for:to:)``. The snapshot stays until ``delete(keeping:)`` removes it.
    ///
    /// Only the call that unpacks receives `progress` events. A `progress` handler also makes the
    /// unpacker read every layer a second time, to compute totals.
    ///
    /// - Throws: A `ContainerizationError` with code `.unsupported` if `image` has no manifest
    ///   for `platform`.
    @discardableResult
    public func unpack(_ image: Image, for platform: Platform = .current, progress: ProgressHandler? = nil) async throws -> URL {
        let key = try await Self.key(of: image, for: platform)
        if let snapshot = self.existing(key) {
            return snapshot
        }

        return try await SnapshotLock.withLock(at: self.lockPath(key)) {
            // Another process can finish the snapshot while this one waits for the lock.
            if let snapshot = self.existing(key) {
                return snapshot
            }

            // Left by a fill that died. No live fill of this snapshot runs while the lock is held.
            try self.removeTemporaryFiles(key)

            let start = ContinuousClock.now
            let entry = self.entryURL(key)
            let temporary = self.path.appendingPathComponent(".\(key.encoded).\(UUID().uuidString).tmp")
            do {
                let unpacker = EXT4Unpacker(capacityInBytes: self.capacityInBytes)
                _ = try await unpacker.unpack(image, for: platform, at: temporary, progress: progress)
                try Self.flush(temporary.absolutePath())
                try Self.publish(temporary.absolutePath(), as: entry.absolutePath())
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            self.logger?.info("unpacked snapshot \(key) of \(image.reference) in \(ContinuousClock.now - start)")
            return entry
        }
    }

    /// Returns the path of the image's existing snapshot for `platform`, or `nil` if it has
    /// none. It never unpacks the image.
    ///
    /// - Throws: A `ContainerizationError` with code `.unsupported` if `image` has no manifest
    ///   for `platform`.
    public func get(_ image: Image, for platform: Platform = .current) async throws -> URL? {
        self.existing(try await Self.key(of: image, for: platform))
    }

    /// Returns the key of the image's snapshot for `platform`, whether or not the snapshot exists.
    ///
    /// The key depends only on the layer digests in the image's manifest, so every image with the
    /// same layers has the same key, and the layers need not be in the content store.
    ///
    /// - Throws: A `ContainerizationError` with code `.unsupported` if `image` has no manifest
    ///   for `platform`.
    public static func key(of image: Image, for platform: Platform = .current) async throws -> ParsedDigest {
        try chainID(of: try await image.manifest(for: platform).layers)
    }

    /// Clones the image's snapshot for `platform` to `destination`.
    ///
    /// The clone belongs to the caller, and a container can attach it writable. On macOS the
    /// clone uses `clonefile(2)` and copies no data. If a copy-on-write clone is not possible,
    /// for example because `destination` is on another volume, the call throws instead of
    /// copying the data. On Linux the clone uses `Mount.clone(to:)`, which copies the data when
    /// the filesystem cannot clone it, and the copy is neither atomic nor exclusive.
    ///
    /// ``delete(keeping:)`` skips the snapshot while it is being cloned.
    ///
    /// - Throws: A `ContainerizationError` with code `.notFound` if the image has no snapshot,
    ///   `.exists` if `destination` exists, and `.unsupported` if the clone cannot be
    ///   copy-on-write on macOS.
    public func clone(_ image: Image, for platform: Platform = .current, to destination: URL) async throws -> Mount {
        let target = destination.absolutePath()
        guard !FileManager.default.fileExists(atPath: target) else {
            throw ContainerizationError(.exists, message: "clone destination \(target) already exists")
        }
        let key = try await Self.key(of: image, for: platform)

        // Clones share the lock. A fill or a delete needs it exclusively, so the snapshot cannot
        // change while it is cloned.
        try await SnapshotLock.withLock(at: self.lockPath(key), shared: true) {
            guard let snapshot = self.existing(key)?.absolutePath() else {
                throw ContainerizationError(.notFound, message: "image \(image.reference) has no snapshot for \(platform.description)")
            }
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
        }
        return Self.mount(target)
    }

    /// Deletes every snapshot that none of `images` references, for any platform.
    ///
    /// It also removes temporary files left by fills that died. It skips a snapshot while a fill,
    /// a clone, or another delete uses it, and it never waits. A container cloned from a deleted
    /// snapshot keeps working, because it has its own copy. If a snapshot cannot be deleted, it
    /// logs the error and continues with the others.
    ///
    /// `images` must include every image that can still start containers. The call throws, and
    /// deletes nothing, if it cannot read the index of one of them.
    ///
    /// - Returns: The keys of the deleted snapshots, as `sha256:<hex>`, and the allocated size
    ///   of the files it removed. Blocks that a removed snapshot shares with clones stay in use
    ///   until the clones are deleted too.
    @discardableResult
    public func delete(keeping images: [Image]) async throws -> (deleted: [String], freed: UInt64) {
        var keep: Set<ParsedDigest> = []
        for image in images {
            // A partial keep set would delete snapshots that are still in use, so an image
            // whose index cannot be read fails the call.
            // `unpack` finds a manifest by its platform, so an entry without one has no snapshot.
            for platform in try await image.index().manifests.compactMap(\.platform) {
                // A manifest that was never pulled, or that cannot be read, cannot have a snapshot.
                do {
                    keep.insert(try await Self.key(of: image, for: platform))
                } catch let error as ContainerizationError where error.code == .notFound || error.code == .invalidArgument {
                    continue
                } catch is DecodingError {
                    continue
                }
            }
        }

        var candidates: Set<ParsedDigest> = []
        var withTemporaries: Set<ParsedDigest> = []
        for name in try FileManager.default.contentsOfDirectory(atPath: self.path.absolutePath()) {
            if let key = Self.snapshotKey(in: name) {
                candidates.insert(key)
            } else if let key = Self.temporaryKey(in: name) {
                candidates.insert(key)
                withTemporaries.insert(key)
            }
        }

        var deleted: [String] = []
        var freed: UInt64 = 0
        for key in candidates.sorted(by: { $0.encoded < $1.encoded }) {
            do {
                try SnapshotLock.withLockIfFree(at: self.lockPath(key)) {
                    if withTemporaries.contains(key) {
                        freed += try self.removeTemporaryFiles(key)
                    }
                    if !keep.contains(key), let snapshot = self.existing(key) {
                        freed += Self.allocatedSize(snapshot.absolutePath())
                        try FileManager.default.removeItem(at: snapshot)
                        deleted.append(key.description)
                    }
                }
            } catch {
                self.logger?.warning("cannot delete snapshot \(key): \(error)")
            }
        }
        return (deleted, freed)
    }

    private func entryURL(_ key: ParsedDigest) -> URL {
        self.path.appendingPathComponent("\(key.encoded).ext4")
    }

    private func lockPath(_ key: ParsedDigest) -> String {
        self.path.appendingPathComponent("\(key.encoded).lock").absolutePath()
    }

    private func existing(_ key: ParsedDigest) -> URL? {
        let snapshot = self.entryURL(key)
        return FileManager.default.fileExists(atPath: snapshot.absolutePath()) ? snapshot : nil
    }

    @discardableResult
    private func removeTemporaryFiles(_ key: ParsedDigest) throws -> UInt64 {
        var freed: UInt64 = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: self.path.absolutePath()) where Self.temporaryKey(in: name) == key {
            let file = self.path.appendingPathComponent(name)
            freed += Self.allocatedSize(file.absolutePath())
            try FileManager.default.removeItem(at: file)
        }
        return freed
    }

    /// The chain ID of `layers`, built as in the OCI image spec but from the layer blob digests
    /// rather than the config's diff IDs. Import verifies blob digests, while nothing checks diff
    /// IDs against the layers, so a crafted config cannot claim another image's snapshot.
    private static func chainID(of layers: [Descriptor]) throws -> ParsedDigest {
        var chain: ParsedDigest?
        for layer in layers {
            let digest = try ParsedDigest(parsing: layer.digest)
            chain = chain.map { ParsedDigest(SHA256.hash(data: Data("\($0) \(digest)".utf8))) } ?? digest
        }
        return chain ?? ParsedDigest(SHA256.hash(data: Data()))
    }

    private static func mount(_ source: String) -> Mount {
        .block(format: "ext4", source: source, destination: "/")
    }

    /// The key in a snapshot file name of the form `<hex>.ext4`.
    private static func snapshotKey(in name: String) -> ParsedDigest? {
        guard name.hasSuffix(".ext4") else {
            return nil
        }
        return try? ParsedDigest(parsing: "sha256:\(name.dropLast(".ext4".count))")
    }

    /// The key in a temporary file name of the form `.<hex>.<uuid>.tmp`.
    private static func temporaryKey(in name: String) -> ParsedDigest? {
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

/// Scoped `flock(2)` locks on snapshot lock files.
private enum SnapshotLock {
    /// Runs `body` while holding the lock, and waits for the lock first if needed. It polls with
    /// `LOCK_NB` instead of blocking in `flock(2)`, so a wait that can last as long as an image
    /// unpack does not hold a thread and stays cancellable. Holders of a shared lock do not
    /// exclude each other, and an exclusive holder excludes all.
    static func withLock<T>(at path: String, shared: Bool = false, _ body: () async throws -> T) async throws -> T {
        let fd = try openLockFile(path)
        defer { unlock(fd) }
        var delay: Duration = .milliseconds(10)
        while try !tryLock(fd, shared ? LOCK_SH : LOCK_EX, path) {
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .milliseconds(100))
        }
        return try await body()
    }

    /// Runs `body` while holding the exclusive lock, if the lock is free. Does nothing if another
    /// holder has it.
    static func withLockIfFree(at path: String, _ body: () throws -> Void) throws {
        let fd = try openLockFile(path)
        defer { unlock(fd) }
        if try tryLock(fd, LOCK_EX, path) {
            try body()
        }
    }

    /// Returns `false` if another holder has a conflicting lock.
    private static func tryLock(_ fd: Int32, _ operation: Int32, _ path: String) throws -> Bool {
        guard flock(fd, operation | LOCK_NB) == 0 else {
            let code = errno
            guard code == EWOULDBLOCK else {
                throw posixError("lock \(path)", code)
            }
            return false
        }
        return true
    }

    private static func unlock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        close(fd)
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
