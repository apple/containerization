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

import SystemPackage

#if canImport(Darwin)
import Darwin
private let os_S_IFMT = mode_t(Darwin.S_IFMT)
private let os_S_IFREG = mode_t(Darwin.S_IFREG)
private let os_S_IFDIR = mode_t(Darwin.S_IFDIR)
private let os_S_IFLNK = mode_t(Darwin.S_IFLNK)
#elseif canImport(Musl)
import CSystem
import Musl
private let os_S_IFMT = Musl.S_IFMT
private let os_S_IFREG = Musl.S_IFREG
private let os_S_IFDIR = Musl.S_IFDIR
private let os_S_IFLNK = Musl.S_IFLNK
#elseif canImport(Glibc)
import Glibc
private let os_S_IFMT = mode_t(Glibc.S_IFMT)
private let os_S_IFREG = mode_t(Glibc.S_IFREG)
private let os_S_IFDIR = mode_t(Glibc.S_IFDIR)
private let os_S_IFLNK = mode_t(Glibc.S_IFLNK)
#endif

/// Duplicates `fd` with `FD_CLOEXEC` set on the new descriptor. Plain `dup(2)`
/// clears the flag, which would let a child process inherit a handle to a
/// directory that was opened close-on-exec.
private func dupCloseOnExec(_ fd: Int32) -> Int32 {
    fcntl(fd, F_DUPFD_CLOEXEC, 0)
}

/// Secure, symlink-safe filesystem operations anchored to a directory file descriptor, with
/// the same semantics on Darwin and Linux.
///
/// Use these in place of path-based `FileManager` or `open(2)` calls whenever any part of a
/// path comes from somewhere you do not control, such as the member names of an archive or
/// the requests of a remote peer. A path-based call resolves the whole path again each time
/// it is used, and follows whatever symlinks it finds, so a symlink planted in the path, or
/// swapped in between a check and a use, can redirect it.
///
/// ## Guarantees
///
/// - Every operation is relative to a directory descriptor. Nothing here resolves a path from
///   the root of the file system.
/// - A symlink is never followed unless the caller explicitly asks for it with
///   ``SymlinkPolicy/followBeneath``. Even then, the link is resolved in this type, one
///   component at a time, against directory descriptors that are already open, and it can
///   never lead above the directory the walk started from.
/// - The primitives never remove or replace anything unless the caller asks for it by name:
///   ``unlink(_:_:)``, ``unlinkRecursive(_:filename:)``, or ``rename(_:_:to:_:)``. A composite says in
///   its documentation what it replaces. For example, ``mkdir(_:_:permissions:makeIntermediates:completion:)``
///   replaces a file or symlink that is in the way of a directory it needs, and never removes a directory.
/// - Every descriptor this type opens or duplicates is close-on-exec, so it is not inherited
///   by child processes.
/// - Problems are reported as typed ``Error`` values, not as `errno` values that differ
///   between platforms.
///
/// ## Two layers
///
/// The **primitives**, in `FileDescriptorOps.swift`, each do one thing relative to a
/// directory descriptor and take no policy. If something is in the way, they report what.
///
/// The **composites**, in `FileDescriptorOps+Composite.swift`, combine primitives into
/// sequences that several callers need and that are easy to get wrong, such as creating a
/// path and then working inside it, or replacing a file atomically. Where a composite has to
/// choose what to do about a symlink, it takes that choice as an explicit argument
/// (``SymlinkPolicy``). Composites use only the public primitives.
///
/// ## Platform notes
///
/// Safety here comes from opening each path component with `O_NOFOLLOW` against a pinned
/// directory descriptor. That works the same way everywhere.
///
/// Where the kernel supports `O_RESOLVE_BENEATH`, it is also passed to `openat`, as a second
/// line of defense against a bug in this type's own path validation. It is available from
/// macOS 15.4 (`xnu-11417.101.15`) and not before, and this package supports macOS 15.0 and
/// later. Because its value is shared with another flag on older kernels, it is only ever
/// passed after an `#available` check. It is not used on Linux, where `openat2(2)` with
/// `RESOLVE_BENEATH` (Linux 5.6 and later) would be the equivalent.
///
/// The type is never instantiated; it exists solely as a namespace.
public enum FileDescriptorOps {

    // MARK: - Nested types

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        /// The path is not a plain relative path: it is absolute, or contains a `..` component.
        case invalidRelativePath
        /// An intermediate path component is missing or is not a directory.
        case invalidPathComponent
        /// The entry is a symlink, which these operations never follow.
        case cannotFollowSymlink
        /// The entry does not exist.
        case notFound
        /// The entry already exists.
        case alreadyExists
        /// The entry has a type the operation cannot use, for example a non-directory
        /// where a directory is needed, or anything but a regular file where a file is read.
        case conflict(EntryType)
        case systemError(String, Int32)

        public var description: String {
            switch self {
            case .invalidRelativePath:
                return "invalid relative path supplied to file descriptor operation"
            case .invalidPathComponent:
                return "an intermediate path component is missing or is not a directory"
            case .cannotFollowSymlink:
                return "cannot follow a symlink in a file descriptor operation"
            case .notFound:
                return "no such entry in file descriptor operation"
            case .alreadyExists:
                return "entry already exists in file descriptor operation"
            case .conflict(let type):
                return "a \(type) entry is in the way of a file descriptor operation"
            case .systemError(let operation, let err):
                return "\(operation) returned error: \(err)"
            }
        }
    }

    /// The type of a directory entry yielded by ``enumerate(_:_:)``.
    public enum EntryType: Sendable, Equatable {
        /// A regular file.
        case regular
        /// A directory. The entry is recursed into; symlinks to directories are
        /// reported as `.symlink` and are never recursed.
        case directory
        /// A symbolic link (to a file or directory).
        case symlink
        /// Any other entry type (device node, named pipe, socket, etc.).
        case other
    }

    /// The metadata of a directory entry, as reported by `stat(2)` without following symlinks.
    public struct FileStatus: Sendable, Equatable {
        public var type: EntryType
        /// The permission bits, including setuid, setgid and sticky.
        public var permissions: FilePermissions
        public var size: Int64
        public var userID: UInt32
        public var groupID: UInt32
        public var modificationSeconds: Int64
        public var modificationNanoseconds: Int
    }

    // MARK: - Primitives
    //
    // Each primitive does one thing relative to a directory descriptor, never
    // follows a symlink, and never removes or replaces anything it was not asked
    // to. Operations that combine primitives, or that have to choose what to do
    // when something is in the way, live in `FileDescriptorOps+Composite.swift`.

    /// Returns the type of the entry `name` in the directory `fd`, without following
    /// a symlink, or `nil` if there is no such entry.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for a directory.
    ///   - name: The name of a direct child of that directory.
    /// - Throws: `FileDescriptorOps.Error.systemError` if the entry cannot be inspected.
    public static func entryType(_ fd: FileDescriptor, _ name: FilePath.Component) throws -> EntryType? {
        var stbuf = stat()
        guard fstatat(fd.rawValue, name.string, &stbuf, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw Error.systemError("stat during file descriptor entry type lookup", errno)
        }
        return entryType(forMode: stbuf.st_mode)
    }

    /// Opens the existing directory `name` in the directory `fd`, without following
    /// a symlink. The returned descriptor is close-on-exec and the caller must close it.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for the parent directory.
    ///   - name: The name of a direct child of that directory.
    /// - Throws: ``Error/notFound`` if there is no such entry, ``Error/cannotFollowSymlink``
    ///   if it is a symlink, ``Error/conflict(_:)`` if it is some other kind of
    ///   non-directory, and ``Error/systemError(_:_:)`` for anything else.
    public static func openDirectory(_ fd: FileDescriptor, _ name: FilePath.Component) throws -> FileDescriptor {
        let newFd = openat(fd.rawValue, name.string, O_NOFOLLOW | O_RDONLY | O_DIRECTORY | O_CLOEXEC | resolveBeneathFlag)
        if newFd >= 0 {
            return FileDescriptor(rawValue: newFd)
        }

        // The failure code for "a symlink or file is in the way" differs between
        // platforms, so look at what is actually there.
        let openErrno = errno
        switch try entryType(fd, name) {
        case nil:
            throw Error.notFound
        case .symlink:
            throw Error.cannotFollowSymlink
        case .regular:
            throw Error.conflict(.regular)
        case .other:
            throw Error.conflict(.other)
        case .directory:
            throw Error.systemError("directory open during file descriptor open", openErrno)
        }
    }

    /// Creates the directory `name` in the directory `fd`.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for the parent directory.
    ///   - name: The name of the directory to create.
    ///   - permissions: The permissions to give the directory (default 0o755).
    /// - Throws: ``Error/alreadyExists`` if anything with that name exists, including a
    ///   symlink, and ``Error/systemError(_:_:)`` for anything else.
    public static func makeDirectory(
        _ fd: FileDescriptor,
        _ name: FilePath.Component,
        permissions: FilePermissions? = nil
    ) throws {
        guard mkdirat(fd.rawValue, name.string, permissions?.rawValue ?? 0o755) == 0 else {
            if errno == EEXIST {
                throw Error.alreadyExists
            }
            throw Error.systemError("directory creation during file descriptor mkdir", errno)
        }
    }

    /// Removes the non-directory entry `name` from the directory `fd`. A symlink is
    /// removed, not followed. This never removes a directory: use
    /// ``unlinkRecursive(_:filename:)`` for that.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for the parent directory.
    ///   - name: The name of the entry to remove.
    /// - Throws: ``Error/notFound`` if there is no such entry, and
    ///   ``Error/systemError(_:_:)`` for anything else, including when the entry is a directory.
    public static func unlink(_ fd: FileDescriptor, _ name: FilePath.Component) throws {
        guard unlinkat(fd.rawValue, name.string, 0) == 0 else {
            if errno == ENOENT {
                throw Error.notFound
            }
            throw Error.systemError("entry removal during file descriptor unlink", errno)
        }
    }

    /// Renames the entry `fromName` in the directory `fromDirectory` to `toName` in the directory
    /// `toDirectory`. The two directories may be the same.
    ///
    /// The rename is atomic, and neither name is followed: a symlink is renamed, not its target.
    ///
    /// **This replaces an existing destination.** If `toName` exists and is not a directory, it is
    /// replaced in one step, and a symlink is replaced rather than written through. As for
    /// `rename(2)`, a directory may only replace an empty directory, and not the reverse.
    ///
    /// - Throws: ``Error/notFound`` if `fromName` does not exist, and ``Error/systemError(_:_:)``
    ///   for anything else.
    public static func rename(
        _ fromDirectory: FileDescriptor,
        _ fromName: FilePath.Component,
        to toDirectory: FileDescriptor,
        _ toName: FilePath.Component
    ) throws {
        guard renameat(fromDirectory.rawValue, fromName.string, toDirectory.rawValue, toName.string) == 0 else {
            if errno == ENOENT {
                throw Error.notFound
            }
            throw Error.systemError("rename during file descriptor rename", errno)
        }
    }

    /// Returns the metadata of an open descriptor.
    ///
    /// - Throws: ``Error/systemError(_:_:)`` if the descriptor cannot be inspected.
    public static func status(of fd: FileDescriptor) throws -> FileStatus {
        var stbuf = stat()
        guard fstat(fd.rawValue, &stbuf) == 0 else {
            throw Error.systemError("stat during file descriptor status", errno)
        }
        return fileStatus(from: stbuf)
    }

    /// Returns the metadata of the entry `name` in the directory `fd`, without following
    /// a symlink, or `nil` if there is no such entry. For a symlink this is the metadata of
    /// the link itself.
    ///
    /// - Throws: ``Error/systemError(_:_:)`` if the entry cannot be inspected.
    public static func status(_ fd: FileDescriptor, _ name: FilePath.Component) throws -> FileStatus? {
        var stbuf = stat()
        guard fstatat(fd.rawValue, name.string, &stbuf, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw Error.systemError("stat during file descriptor status", errno)
        }
        return fileStatus(from: stbuf)
    }

    /// Opens the existing regular file `name` in the directory `fd` for reading, without
    /// following a symlink. The returned descriptor is close-on-exec and the caller must close it.
    ///
    /// The file is opened non-blocking and checked after it is open, so a FIFO, device or
    /// socket in its place is refused instead of blocking the caller or being read.
    ///
    /// - Throws: ``Error/notFound`` if there is no such entry, ``Error/cannotFollowSymlink``
    ///   if it is a symlink, ``Error/conflict(_:)`` if it is not a regular file, and
    ///   ``Error/systemError(_:_:)`` for anything else.
    public static func openFile(_ fd: FileDescriptor, _ name: FilePath.Component) throws -> FileDescriptor {
        let newFd = openat(fd.rawValue, name.string, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC | resolveBeneathFlag)
        guard newFd >= 0 else {
            let openErrno = errno
            switch try entryType(fd, name) {
            case nil:
                throw Error.notFound
            case .symlink:
                throw Error.cannotFollowSymlink
            case .other:
                throw Error.conflict(.other)
            case .regular, .directory:
                throw Error.systemError("file open during file descriptor open", openErrno)
            }
        }

        let opened = FileDescriptor(rawValue: newFd)
        do {
            let type = try status(of: opened).type
            guard type == .regular else {
                throw Error.conflict(type)
            }
            return opened
        } catch {
            try? opened.close()
            throw error
        }
    }

    /// Creates the new regular file `name` in the directory `fd`, open for writing. The
    /// returned descriptor is close-on-exec and the caller must close it.
    ///
    /// The file is created exclusively and without following a symlink, so this never writes
    /// through, or over, anything that already exists.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for the parent directory.
    ///   - name: The name of the file to create.
    ///   - permissions: The permissions to give the file (default 0o644), subject to the umask.
    /// - Throws: ``Error/alreadyExists`` if anything with that name exists, including a
    ///   symlink, and ``Error/systemError(_:_:)`` for anything else.
    public static func createFile(
        _ fd: FileDescriptor,
        _ name: FilePath.Component,
        permissions: FilePermissions? = nil
    ) throws -> FileDescriptor {
        let newFd = openat(
            fd.rawValue,
            name.string,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | resolveBeneathFlag,
            permissions?.rawValue ?? 0o644
        )
        guard newFd >= 0 else {
            if errno == EEXIST {
                throw Error.alreadyExists
            }
            throw Error.systemError("file creation during file descriptor create", errno)
        }
        return FileDescriptor(rawValue: newFd)
    }

    /// Creates the symlink `name` in the directory `fd`, pointing at `target`.
    ///
    /// `target` is stored as given and is never resolved, so it may be absolute or contain `..`.
    ///
    /// - Throws: ``Error/alreadyExists`` if anything with that name exists, and
    ///   ``Error/systemError(_:_:)`` for anything else.
    public static func makeSymlink(_ fd: FileDescriptor, _ name: FilePath.Component, target: String) throws {
        guard symlinkat(target, fd.rawValue, name.string) == 0 else {
            if errno == EEXIST {
                throw Error.alreadyExists
            }
            throw Error.systemError("symlink creation during file descriptor symlink", errno)
        }
    }

    /// The longest symlink target ``readSymlink(_:_:)`` will read, in bytes.
    ///
    /// This is a sanity bound, not the limit of any particular platform, and `PATH_MAX` is the wrong
    /// number to use for it. `PATH_MAX` is only the longest path that the system calls accept as an
    /// argument (4096 on Linux, 1024 on macOS). It is not a promise about what a filesystem can store
    /// or report, so a filesystem that is not bound by it would have links refused that really exist.
    /// 16 KiB is four times the largest `PATH_MAX` of the platforms supported here, so every link those
    /// platforms can create is read in full, while a filesystem that misbehaves still cannot make
    /// this allocate much.
    private static let maximumSymlinkTargetLength = 16 * 1024

    /// Returns the target of the symlink `name` in the directory `fd`, without following it.
    /// The target is decoded as UTF-8, and invalid sequences are replaced. A target longer than
    /// 16 KiB is refused.
    ///
    /// - Throws: ``Error/notFound`` if there is no such entry, ``Error/conflict(_:)`` if it is
    ///   not a symlink, and ``Error/systemError(_:_:)`` for anything else, including a target that is too long.
    public static func readSymlink(_ fd: FileDescriptor, _ name: FilePath.Component) throws -> String {
        // Grow the buffer until the target fits, instead of asking for its length first (the `st_size` of
        // `fstatat`) and sizing one buffer to match. A symlink is not locked, so it can be replaced between
        // the two calls, and a buffer sized for the old target would silently cut off a longer new one.
        // Here a read that fills the buffer is never trusted, so a target that is returned was read in full.
        var capacity = 256
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let count = readlinkat(fd.rawValue, name.string, &buffer, capacity)
            guard count >= 0 else {
                let readlinkErrno = errno
                switch try entryType(fd, name) {
                case nil:
                    throw Error.notFound
                case .symlink:
                    throw Error.systemError("symlink read during file descriptor readlink", readlinkErrno)
                case let type?:
                    throw Error.conflict(type)
                }
            }
            if count < capacity {
                return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            // The buffer was filled, so the target may have been cut off. Retry with a larger one.
            guard capacity < maximumSymlinkTargetLength else {
                throw Error.systemError("symlink read during file descriptor readlink", ENAMETOOLONG)
            }
            capacity *= 2
        }
    }

    /// Recursively removes a direct child of the directory at `fd`.
    ///
    /// Symlinks are removed, not followed. `.` and `..` are ignored. A child that
    /// does not exist is not an error.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for the parent directory.
    ///   - filename: The name of the child to remove.
    /// - Throws: `FileDescriptorOps.Error` if system errors occur.
    public static func unlinkRecursive(_ fd: FileDescriptor, filename: FilePath.Component) throws {
        guard filename.string != "." && filename.string != ".." else {
            return
        }

        guard unlinkat(fd.rawValue, filename.string, 0) != 0 else {
            return
        }

        guard errno != ENOENT else {
            return
        }

        guard errno == EPERM || errno == EISDIR else {
            throw Error.systemError("file removal during file descriptor unlink", errno)
        }

        let componentFd = openat(fd.rawValue, filename.string, O_NOFOLLOW | O_RDONLY | O_DIRECTORY | O_CLOEXEC | resolveBeneathFlag)
        guard componentFd >= 0 else {
            throw Error.systemError("directory open during file descriptor unlink", errno)
        }
        let componentFileDescriptor = FileDescriptor(rawValue: componentFd)
        defer { try? componentFileDescriptor.close() }

        // Open the directory stream using a duplicate fd that closedir() will close.
        let ownedFd = dupCloseOnExec(componentFd)
        guard ownedFd >= 0 else {
            throw Error.systemError("directory dup during file descriptor unlink", errno)
        }
        guard let dir = fdopendir(ownedFd) else {
            let savedErrno = errno
            close(ownedFd)
            throw Error.systemError("directory opendir during file descriptor unlink", savedErrno)
        }
        defer { closedir(dir) }

        while let entry = readdir(dir) {
            let childComponent = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: Int(NAME_MAX) + 1) {
                    let name = String(decodingCString: $0, as: UTF8.self)
                    return FilePath.Component(name)
                }
            }
            guard let childComponent else {
                throw Error.systemError("directory entry processing during file descriptor unlink", errno)
            }
            try unlinkRecursive(componentFileDescriptor, filename: childComponent)
        }

        if unlinkat(fd.rawValue, filename.string, AT_REMOVEDIR) != 0 {
            throw Error.systemError("directory removal during file descriptor unlink", errno)
        }
    }

    /// Recursively enumerates the contents of `fd` without following symbolic links.
    ///
    /// Each entry — file, directory, symlink, or other type — is reported to
    /// `body` with a path relative to `fd`. Directories are reported before their
    /// contents (pre-order) and then recursed. A symlink whose target is a directory
    /// is reported as `.symlink` and is never followed, so traversal cannot escape
    /// the tree rooted at `fd` regardless of where symlinks point.
    ///
    /// `fd` must be an open file descriptor for a directory.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for the root directory to enumerate.
    ///   - body: Called once per entry. `path` is relative to `fd`; `type`
    ///     identifies the kind of entry; `parentFd` is the open file descriptor
    ///     for the directory that contains the entry. The last component of `path`
    ///     is the entry's filename; together with `parentFd` it allows the body to
    ///     open the entry via
    ///     `openat(parentFd.rawValue, path.lastComponent!.string, O_NOFOLLOW | O_CLOEXEC …)`
    ///     without reconstructing an absolute path, preserving the TOCTOU safety
    ///     of the traversal end-to-end. `parentFd` must not be closed within the
    ///     body call, or used after the call returns. Throw to abort.
    /// - Throws: `FileDescriptorOps.Error` on system errors; any error thrown by
    ///   `body` is propagated unchanged.
    public static func enumerate(
        _ fd: FileDescriptor,
        _ body: (_ path: FilePath, _ type: EntryType, _ parentFd: FileDescriptor) throws -> Void
    ) throws {
        try enumerateHelper(fd, relativePath: FilePath(""), body: body)
    }

    // MARK: - Canonical path

    #if canImport(Darwin)
    /// Returns the canonical path for `fd` using `F_GETPATH`.
    public static func getCanonicalPath(_ fd: FileDescriptor) throws -> FilePath {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd.rawValue, F_GETPATH, &buffer) != -1 else {
            throw Errno(rawValue: errno)
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return FilePath(String(decoding: bytes, as: UTF8.self))
    }
    #elseif canImport(Glibc) || canImport(Musl)
    /// Returns the canonical path for `fd` via `/proc/self/fd`.
    public static func getCanonicalPath(_ fd: FileDescriptor) throws -> FilePath {
        let fdPath = "/proc/self/fd/\(fd.rawValue)"
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = readlink(fdPath, &buffer, buffer.count - 1)
        guard len > 0 else {
            throw Error.systemError("readlink", errno)
        }
        let bytes = buffer.prefix(len).map { UInt8(bitPattern: $0) }
        return FilePath(String(decoding: bytes, as: UTF8.self))
    }
    #endif

    // MARK: - Private helpers

    /// `O_RESOLVE_BENEATH` where the kernel supports it, and 0 everywhere else.
    ///
    /// With this flag the kernel refuses an `openat` whose path is absolute or would leave the
    /// directory it is relative to. Every path passed to `openat` here is a single validated
    /// component, so it changes nothing when the code is correct. It exists to turn a bug in
    /// the validation into a failed open instead of an escape.
    ///
    /// `open(2)` and `openat(2)` honor the flag from macOS 15.4 (`xnu-11417.101.15`), and
    /// not before. A refused path fails with `EACCES` on macOS 15.4 and later 15.x releases, and
    /// with `ENOTCAPABLE` from macOS 26.0 (`xnu-12377.1.9`). Its value, `0x1000`, is `FMARK` on
    /// older kernels, so the flag must not be passed to one: the `#available` check is the only
    /// thing that makes it safe. The value is defined here, and not taken from the SDK, so this
    /// builds with an SDK that predates the flag.
    static var resolveBeneathFlag: Int32 {
        #if canImport(Darwin)
        if #available(macOS 15.4, *) {
            return 0x1000
        }
        #endif
        return 0
    }

    private static func enumerateHelper(
        _ fd: FileDescriptor,
        relativePath: FilePath,
        body: (_ path: FilePath, _ type: EntryType, _ parentFd: FileDescriptor) throws -> Void
    ) throws {
        // fdopendir takes ownership of the fd passed to it and closes it via
        // closedir. Duplicate so the caller's fd remains open.
        let dupFd = dupCloseOnExec(fd.rawValue)
        guard dupFd >= 0 else {
            throw Error.systemError("dup during file descriptor enumerate", errno)
        }
        guard let dir = fdopendir(dupFd) else {
            let savedErrno = errno
            try? FileDescriptor(rawValue: dupFd).close()
            throw Error.systemError("fdopendir during file descriptor enumerate", savedErrno)
        }
        defer { closedir(dir) }

        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: Int(NAME_MAX) + 1) {
                    String(decodingCString: $0, as: UTF8.self)
                }
            }
            guard name != "." && name != ".." else { continue }
            guard let component = FilePath.Component(name) else { continue }

            let entryPath = relativePath.appending(component)
            let entryType = resolveEntryType(parentFd: fd.rawValue, name: name, dtype: entry.pointee.d_type)

            // Pass fd (the parent directory) so the body can use
            // openat(parentFd.rawValue, path.lastComponent!.string, O_NOFOLLOW …)
            // rather than reconstructing an absolute path, keeping the fd chain unbroken.
            try body(entryPath, entryType, fd)

            guard entryType == .directory else { continue }

            // Open the child directory with O_NOFOLLOW to guarantee we are
            // entering a real directory and not a symlink that was swapped in
            // between readdir and here.
            let childFd = openat(fd.rawValue, name, O_NOFOLLOW | O_RDONLY | O_DIRECTORY | O_CLOEXEC | resolveBeneathFlag)
            guard childFd >= 0 else {
                throw Error.systemError("openat during file descriptor enumerate", errno)
            }
            let childDescriptor = FileDescriptor(rawValue: childFd)
            defer { try? childDescriptor.close() }
            try enumerateHelper(childDescriptor, relativePath: entryPath, body: body)
        }
    }

    private static func resolveEntryType(parentFd: Int32, name: String, dtype: UInt8) -> EntryType {
        switch dtype {
        case UInt8(DT_REG): return .regular
        case UInt8(DT_DIR): return .directory
        case UInt8(DT_LNK): return .symlink
        case UInt8(DT_UNKNOWN):
            // Some filesystems (NFS, ext2/3) report DT_UNKNOWN; fall back to fstatat.
            var stbuf = stat()
            guard fstatat(parentFd, name, &stbuf, AT_SYMLINK_NOFOLLOW) == 0 else { return .other }
            return entryType(forMode: stbuf.st_mode)
        default: return .other
        }
    }

    private static func entryType(forMode mode: mode_t) -> EntryType {
        switch mode & os_S_IFMT {
        case os_S_IFREG: return .regular
        case os_S_IFDIR: return .directory
        case os_S_IFLNK: return .symlink
        default: return .other
        }
    }

    private static func fileStatus(from stbuf: stat) -> FileStatus {
        #if canImport(Darwin)
        let mtime = stbuf.st_mtimespec
        #else
        let mtime = stbuf.st_mtim
        #endif
        return FileStatus(
            type: entryType(forMode: stbuf.st_mode),
            permissions: FilePermissions(rawValue: stbuf.st_mode & 0o7777),
            size: Int64(stbuf.st_size),
            userID: UInt32(stbuf.st_uid),
            groupID: UInt32(stbuf.st_gid),
            modificationSeconds: Int64(mtime.tv_sec),
            modificationNanoseconds: Int(mtime.tv_nsec)
        )
    }

    /// Rejects anything that is not a plain relative path: an absolute path, or a
    /// path with a `..` component. An empty path is allowed and means "the
    /// directory itself". Callers that accept untrusted names, such as archive
    /// member names, decide whether to strip or reject before calling in.
    static func validateRelativePath(_ path: FilePath) throws {
        guard !path.isAbsolute else {
            throw Error.invalidRelativePath
        }
        guard !(path.components.contains { $0 == ".." }) else {
            throw Error.invalidRelativePath
        }
    }
}
