//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

import CShim
import Foundation

#if canImport(Musl)
import Musl
private let _mount = Musl.mount
private let _umount = Musl.umount2
#elseif canImport(Glibc)
import Glibc
private let _mount = Glibc.mount
private let _umount = Glibc.umount2
#endif

// Mount package modeled closely from containerd's: https://github.com/containerd/containerd/tree/main/core/mount

/// `Mount` models a Linux mount (although potentially could be used on other unix platforms), and
/// provides a simple interface to mount what the type describes.
public struct Mount: Sendable {
    // Type specifies the host-specific of the mount.
    public var type: String
    // Source specifies where to mount from. Depending on the host system, this
    // can be a source path or device.
    public var source: String
    // Target specifies an optional subdirectory as a mountpoint.
    public var target: String
    // Options contains zero or more fstab-style mount options.
    public var options: [String]

    public init(type: String, source: String, target: String, options: [String]) {
        self.type = type
        self.source = source
        self.target = target
        self.options = options
    }
}

extension Mount {
    #if canImport(Glibc)
    internal typealias Flag = Int
    #else
    internal typealias Flag = Int32
    #endif

    internal struct FlagBehavior {
        let clear: Bool
        let flag: Flag

        public init(_ clear: Bool, _ flag: Flag) {
            self.clear = clear
            self.flag = flag
        }
    }

    #if os(Linux)
    internal static let flagsDictionary: [String: FlagBehavior] = [
        "async": .init(true, MS_SYNCHRONOUS),
        "atime": .init(true, MS_NOATIME),
        "bind": .init(false, MS_BIND),
        "defaults": .init(false, 0),
        "dev": .init(true, MS_NODEV),
        "diratime": .init(true, MS_NODIRATIME),
        "dirsync": .init(false, MS_DIRSYNC),
        "exec": .init(true, MS_NOEXEC),
        "mand": .init(false, MS_MANDLOCK),
        "noatime": .init(false, MS_NOATIME),
        "nodev": .init(false, MS_NODEV),
        "nodiratime": .init(false, MS_NODIRATIME),
        "noexec": .init(false, MS_NOEXEC),
        "nomand": .init(true, MS_MANDLOCK),
        "norelatime": .init(true, MS_RELATIME),
        "nostrictatime": .init(true, MS_STRICTATIME),
        "nosuid": .init(false, MS_NOSUID),
        "rbind": .init(false, MS_BIND | MS_REC),
        "relatime": .init(false, MS_RELATIME),
        "remount": .init(false, MS_REMOUNT),
        "ro": .init(false, MS_RDONLY),
        "rw": .init(true, MS_RDONLY),
        "strictatime": .init(false, MS_STRICTATIME),
        "suid": .init(true, MS_NOSUID),
        "sync": .init(false, MS_SYNCHRONOUS),
    ]

    internal struct MountOptions {
        var flags: Int32
        var data: [String]

        public init(_ flags: Int32 = 0, data: [String] = []) {
            self.flags = flags
            self.data = data
        }
    }

    /// Whether the mount is read only.
    public var readOnly: Bool {
        for option in self.options {
            if option == "ro" {
                return true
            }
        }
        return false
    }

    /// Mount the mount relative to `root` with the current set of data in the object.
    ///
    /// Optionally provide `createWithPerms` to set the permissions for the directory that
    /// it will be mounted at.
    public func mount(root: String, createWithPerms: Int16? = nil) throws {
        let fd = try secureResolveInRoot(root: root)
        defer { close(fd) }

        let realPath = try readlinkProc(fd: fd)
        try self.mountToTarget(target: realPath, createWithPerms: createWithPerms, targetResolved: true)
    }

    /// Open a path relative to `dirFd` using `openat2(2)` with `RESOLVE_IN_ROOT`.
    ///
    /// All symlink resolution is confined to the directory tree beneath `dirFd`.
    /// Returns the file descriptor on success, or -1 on failure (with errno set).
    private func openInRoot(dirFd: Int32, path: String, flags: Int32, mode: UInt64 = 0) -> Int32 {
        path.withCString { cPath in
            var how = cz_open_how(
                flags: UInt64(flags),
                mode: mode,
                resolve: UInt64(RESOLVE_IN_ROOT)
            )
            return CZ_openat2(dirFd, cPath, &how, MemoryLayout<cz_open_how>.size)
        }
    }

    private func secureResolveInRoot(root: String) throws -> Int32 {
        let rootFd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFd >= 0 else {
            throw Error.errno(errno, "failed to open rootfs '\(root)'")
        }

        // Determine if the leaf mount point should be a file or directory.
        let opts = parseMountOptions()
        let isBindMount = (opts.flags & Int32(MS_BIND)) != 0
        var leafIsFile = false
        if isBindMount {
            var sourceStat = stat()
            if stat(self.source, &sourceStat) == 0 {
                leafIsFile = (sourceStat.st_mode & S_IFMT) == S_IFREG
            }
        }

        // Normalize target to a relative path for openat2.
        let relativePath = self.target
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")

        guard !relativePath.isEmpty else {
            return rootFd
        }

        // Fast path: try openat2 with RESOLVE_IN_ROOT for the full path.
        let openFlags: Int32 =
            leafIsFile
            ? (O_RDONLY | O_CLOEXEC)
            : (O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let fd = openInRoot(dirFd: rootFd, path: relativePath, flags: openFlags)
        if fd >= 0 {
            close(rootFd)
            return fd
        }

        guard errno == ENOENT else {
            let savedErrno = errno
            close(rootFd)
            throw Error.errno(savedErrno, "failed to resolve '\(self.target)' in rootfs")
        }

        // Part of the path doesn't exist. Use openat2 to find the deepest
        // existing ancestor, then create the missing components.
        return try createMountTarget(
            rootFd: rootFd, relativePath: relativePath, leafIsFile: leafIsFile
        )
    }

    private func createMountTarget(
        rootFd: Int32,
        relativePath: String,
        leafIsFile: Bool
    ) throws -> Int32 {
        let components = relativePath.split(separator: "/").map(String.init)
        var currentFd = rootFd
        var resultFd: Int32 = -1

        // Centralized cleanup. On success resultFd holds the fd we return,
        // so we avoid closing it. On error resultFd is -1 and we close
        // everything.
        defer {
            if currentFd != rootFd && currentFd != resultFd { close(currentFd) }
            if rootFd != resultFd { close(rootFd) }
        }

        func fail(_ savedErrno: Int32, _ message: String) throws -> Never {
            throw Error.errno(savedErrno, message)
        }

        // Find the deepest existing directory using openat2 with RESOLVE_IN_ROOT.
        var firstMissing = 0
        for i in 0..<components.count {
            let subpath = components[0...i].joined(separator: "/")
            let nextFd = openInRoot(dirFd: rootFd, path: subpath, flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if nextFd < 0 {
                firstMissing = i
                break
            }
            if currentFd != rootFd { close(currentFd) }
            currentFd = nextFd
            firstMissing = i + 1
        }

        // Create missing directories and the leaf mount point.
        for i in firstMissing..<components.count {
            let component = components[i]
            let isLast = (i == components.count - 1)

            if isLast && leafIsFile {
                // Use mknodat to create a regular file without opening it.
                let rc = mknodat(currentFd, component, S_IFREG | 0o644, 0)
                if rc != 0 && errno != EEXIST {
                    try fail(errno, "failed to create mount point file '\(component)'")
                }
                let pathFd = openat(currentFd, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard pathFd >= 0 else {
                    try fail(errno, "failed to re-open mount point file '\(component)'")
                }
                resultFd = pathFd
                return resultFd
            }

            guard mkdirat(currentFd, component, 0o755) == 0 else {
                try fail(errno, "failed to create directory '\(component)'")
            }

            let dirFd = openat(currentFd, component, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            guard dirFd >= 0 else {
                try fail(errno, "failed to open created directory '\(component)'")
            }

            if isLast {
                resultFd = dirFd
                return resultFd
            }

            if currentFd != rootFd { close(currentFd) }
            currentFd = dirFd
        }

        // All components already existed.
        resultFd = currentFd
        return resultFd
    }

    /// Resolve the real filesystem path for an open fd via /proc/self/fd.
    private func readlinkProc(fd: Int32) throws -> String {
        let procPath = "/proc/self/fd/\(fd)"
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let len = readlink(procPath, &buffer, buffer.count - 1)
        guard len > 0 else {
            throw Error.errno(errno, "readlink failed for '\(procPath)'")
        }
        return buffer.prefix(len).withUnsafeBufferPointer { buf in
            String(decoding: buf.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// Mount the mount with the current set of data in the object. Optionally
    /// provide `createWithPerms` to set the permissions for the directory that
    /// it will be mounted at.
    public func mount(createWithPerms: Int16? = nil) throws {
        try self.mountToTarget(target: self.target, createWithPerms: createWithPerms)
    }

    private func mountToTarget(target: String, createWithPerms: Int16?, targetResolved: Bool = false) throws {
        let pageSize = sysconf(Int32(_SC_PAGESIZE))

        let opts = parseMountOptions()
        let dataString = opts.data.joined(separator: ",")
        if dataString.count > pageSize {
            throw Error.validation("data string exceeds page size (\(dataString.count) > \(pageSize))")
        }

        let propagationTypes: Int32 = Int32(MS_SHARED) | Int32(MS_PRIVATE) | Int32(MS_SLAVE) | Int32(MS_UNBINDABLE)

        // Ensure propagation type change flags aren't included in other calls.
        let originalFlags = opts.flags & ~(propagationTypes)

        // When targetResolved is true, the target path has already been securely
        // resolved and the mount point created by secureResolveInRoot. Skip
        // directory/file creation to avoid following symlinks in the target path.
        if !targetResolved {
            let targetURL = URL(fileURLWithPath: target)
            let targetParent = targetURL.deletingLastPathComponent().path
            if let perms = createWithPerms {
                try mkdirAll(targetParent, perms)
            }

            // For bind mounts, check if the source is a file and create the target accordingly.
            let isBindMount = (originalFlags & Int32(MS_BIND)) != 0
            if isBindMount {
                var sourceIsFile = false
                var sourceStat = stat()
                if stat(self.source, &sourceStat) == 0 {
                    sourceIsFile = (sourceStat.st_mode & S_IFMT) == S_IFREG
                }

                if sourceIsFile {
                    // Create parent directories and touch the target file
                    try mkdirAll(targetParent, 0o755)
                    let fd = open(target, O_WRONLY | O_CREAT, 0o644)
                    if fd >= 0 {
                        close(fd)
                    }
                } else {
                    try mkdirAll(target, 0o755)
                }
            } else {
                try mkdirAll(target, 0o755)
            }
        }

        if opts.flags & Int32(MS_REMOUNT) == 0 || !dataString.isEmpty {
            guard _mount(self.source, target, self.type, UInt(originalFlags), dataString) == 0 else {
                throw Error.errno(
                    errno,
                    "failed initial mount source=\(self.source) target=\(target) type=\(self.type) data=\(dataString)"
                )
            }
        }

        if opts.flags & propagationTypes != 0 {
            // Change the propagation type.
            let pflags = propagationTypes | Int32(MS_REC) | Int32(MS_SILENT)
            guard _mount("", target, "", UInt(opts.flags & pflags), "") == 0 else {
                throw Error.errno(errno, "failed propagation change mount")
            }
        }

        let bindReadOnlyFlags = Int32(MS_BIND) | Int32(MS_RDONLY)
        if originalFlags & bindReadOnlyFlags == bindReadOnlyFlags {
            guard _mount("", target, "", UInt(originalFlags | Int32(MS_REMOUNT)), "") == 0 else {
                throw Error.errno(errno, "failed bind mount")
            }
        }
    }

    private func mkdirAll(_ name: String, _ perm: Int16) throws {
        try FileManager.default.createDirectory(
            atPath: name,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: perm]
        )
    }

    private func parseMountOptions() -> MountOptions {
        var mountOpts = MountOptions()
        for option in self.options {
            if let entry = Self.flagsDictionary[option], entry.flag != 0 {
                if entry.clear {
                    mountOpts.flags &= ~Int32(entry.flag)
                } else {
                    mountOpts.flags |= Int32(entry.flag)
                }
            } else {
                mountOpts.data.append(option)
            }
        }
        return mountOpts
    }

    /// `Mount` errors
    public enum Error: Swift.Error, CustomStringConvertible {
        case errno(Int32, String)
        case validation(String)

        public var description: String {
            switch self {
            case .errno(let errno, let message):
                return "mount failed with errno \(errno): \(message)"
            case .validation(let message):
                return "failed during validation: \(message)"
            }
        }
    }
    #endif
}
