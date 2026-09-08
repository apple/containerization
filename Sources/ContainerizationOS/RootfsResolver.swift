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

import CShim
import SystemPackage

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Symlink-safe filesystem access confined to a root directory, built on
/// openat2(2) with RESOLVE_IN_ROOT.
///
/// Every component is resolved by the kernel as if the calling process were
/// chrooted into the directory referenced by the anchoring file descriptor:
/// absolute symlinks, `..`, and absolute paths are all interpreted relative to
/// that root, so a resolved path can never escape it. This is the confinement
/// callers need when acting on a path that originates from an untrusted
/// container image but must stay within the container's root filesystem.
///
/// Requires Linux 5.6+ for openat2(2).
public enum RootfsResolver {
    /// `O_PATH`. The Swift libc overlays don't reliably surface it, and callers
    /// outside `ContainerizationOS` don't depend on `CShim`. Opens a descriptor
    /// usable only for path operations (`fstat`, reopen via `/proc/self/fd`), so
    /// it never blocks on a FIFO or device.
    public static let oPath = Int32(CZ_O_PATH)

    public enum Error: Swift.Error, CustomStringConvertible {
        case errno(Int32, String)

        public var description: String {
            switch self {
            case .errno(let err, let message):
                return "\(message): \(String(cString: strerror(err)))"
            }
        }
    }

    /// Open path relative to dirFd using openat2(2) with RESOLVE_IN_ROOT.
    ///
    /// Symlinks are followed but confined to the tree beneath dirFd; magic
    /// links (e.g. /proc/*/fd) are rejected. Returns the open file descriptor,
    /// or -1 with errno set on failure (EINVAL if path contains a NUL).
    public static func openInRoot(dirFd: Int32, path: String, flags: Int32, mode: UInt64 = 0) -> Int32 {
        // Avoid withCString truncation on security-sensitive paths.
        guard !path.utf8.contains(0) else {
            errno = EINVAL
            return -1
        }
        return path.withCString { cPath in
            var how = cz_open_how(
                flags: UInt64(flags),
                mode: mode,
                resolve: UInt64(RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS)
            )
            return CZ_openat2(dirFd, cPath, &how, MemoryLayout<cz_open_how>.size)
        }
    }

    /// Ensure the directory `path` (and any missing parents) exists beneath dirFd,
    /// confined to it, then run `body` with the descriptor of the leaf directory.
    /// Components that already exist — including symlinks — are resolved within the
    /// root; missing components are created. The descriptor passed to `body` is
    /// valid only for its duration and must not be closed by it.
    public static func withDirectoryInRoot<T>(
        dirFd rootFd: Int32, path: String, perms: mode_t = 0o755, _ body: (Int32) throws -> T
    ) throws -> T {
        // Avoid C string truncation before the mkdirat/openat component walk.
        guard !path.utf8.contains(0) else {
            throw Error.errno(EINVAL, "resolve directory '\(path)' within root, path contains a NUL byte")
        }
        // Anchoring at "/" lets lexical normalization clamp ".." at the root and
        // drop ".", leaving only real-name components for the creation walk.
        let components = FilePath("/" + path).lexicallyNormalized().components.map(\.string)
        guard !components.isEmpty else {
            return try body(rootFd)
        }

        var currentFd = rootFd
        defer { if currentFd != rootFd { close(currentFd) } }

        var firstMissing = components.count
        for i in components.indices {
            let subpath = components[0...i].joined(separator: "/")
            let fd = openInRoot(dirFd: rootFd, path: subpath, flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if fd < 0 {
                guard errno == ENOENT else {
                    throw Error.errno(errno, "resolve '\(subpath)' within root")
                }
                firstMissing = i
                break
            }
            if currentFd != rootFd { close(currentFd) }
            currentFd = fd
        }

        // Create the missing tail. Each created directory is reopened with
        // O_NOFOLLOW so a concurrently swapped-in symlink cannot redirect us.
        for i in firstMissing..<components.count {
            let component = components[i]
            if mkdirat(currentFd, component, perms) != 0 && errno != EEXIST {
                throw Error.errno(errno, "create directory '\(component)'")
            }
            let dirFd = openat(currentFd, component, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            guard dirFd >= 0 else {
                throw Error.errno(errno, "open created directory '\(component)'")
            }
            if currentFd != rootFd { close(currentFd) }
            currentFd = dirFd
        }

        return try body(currentFd)
    }

    /// Create the directory `path` (and any missing parents) beneath dirFd,
    /// confined to it. Succeeds if the directory already exists.
    public static func createDirectoryInRoot(dirFd rootFd: Int32, path: String, perms: mode_t = 0o755) throws {
        try withDirectoryInRoot(dirFd: rootFd, path: path, perms: perms) { _ in }
    }
}

#endif
