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

/// Static utility functions for secure, symlink-safe filesystem operations
/// anchored to a file descriptor.
///
/// All operations use `openat`/`mkdirat`/`unlinkat` anchored to the supplied
/// file descriptor. Every path component is opened with `O_NOFOLLOW`, so a
/// symlink is never followed while walking a path, and every descriptor this
/// type opens or duplicates is close-on-exec so it is not inherited by child
/// processes. The type is never instantiated; it exists solely as a namespace.
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
        /// A non-directory entry of the given type is in the way of an operation that needs a directory.
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
        let newFd = openat(fd.rawValue, name.string, O_NOFOLLOW | O_RDONLY | O_DIRECTORY | O_CLOEXEC)
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

        let componentFd = openat(fd.rawValue, filename.string, O_NOFOLLOW | O_RDONLY | O_DIRECTORY | O_CLOEXEC)
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
            let childFd = openat(fd.rawValue, name, O_NOFOLLOW | O_RDONLY | O_DIRECTORY | O_CLOEXEC)
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
