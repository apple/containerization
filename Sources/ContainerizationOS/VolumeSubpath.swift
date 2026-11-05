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

import CShim
import SystemPackage

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Utilities to facilitate the mounting of subpaths within kubernetes volumes.
/// A subpath mount is a special bind mount that binds to a "subpath" within
/// the source volume. For example: volume A contains "/A/foo/bar". Mounting A
/// with subpath "foo" at "/mnt" binds "/A/foo" to "/mnt", so the container
/// sees only "bar" within "/mnt".
///
/// ref: https://kubernetes.io/docs/concepts/storage/volumes/#using-subpath
public enum VolumeSubpath {
    /// In order to pass the subpath through the OCI.Mount Spec/Bundle, we use a
    /// custom mount option. The `x-` prefix follows `mount(8)`, where such options
    /// are metadata about the mount and do not change how it mounts.
    private static let optionPrefix = "x-containerization.subpath="

    /// The mount option that carries `subpath` to the guest; see `extract`.
    public static func toMountOption(_ subpath: String) -> String {
        optionPrefix + subpath
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// The subpath is not a relative path of plain names.
        case invalid(subpath: String, reason: String)
        /// A mount has no subpath option.
        case missing(options: [String])
        /// A mount with a subpath option is not a non-recursive bind mount.
        case notBind
        /// The subpath cannot be opened or created beneath the volume.
        case resolve(subpath: String, errno: Int32)

        public var description: String {
            switch self {
            case .invalid(let subpath, let reason):
                return "invalid subpath '\(subpath)': \(reason)"
            case .missing(let options):
                return "no subpath option in \(options)"
            case .notBind:
                return "a subpath needs a non-recursive bind mount"
            case .resolve(let subpath, let code):
                return "subpath '\(subpath)': cannot be opened: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Whether `options` carry a subpath. Throws if the mount is not a bind, since only a bind has a source to resolve beneath.
    public static func isSubpathMount(
        options: [String]
    ) throws(Error) -> Bool {
        guard options.contains(where: { $0.hasPrefix(optionPrefix) }) else {
            return false
        }
        // Staging binds non-recursively, so `rbind` would silently lose nested mounts.
        guard options.contains("bind") && !options.contains("rbind") else {
            throw .notBind
        }

        return true
    }

    /// The subpath and the remaining options, in order. The guest strips the subpath before passing options to runc.
    public static func extract(
        from options: [String]
    ) throws(Error) -> (subpath: String, options: [String]) {
        var subpath: String?
        var rest: [String] = []

        for option in options {
            guard option.hasPrefix(optionPrefix) else {
                rest.append(option)
                continue
            }

            let value = String(option.dropFirst(optionPrefix.count))
            guard subpath == nil else {
                throw .invalid(subpath: value, reason: "it is given more than once")
            }

            subpath = value
        }

        guard let subpath else {
            throw .missing(options: options)
        }

        return (subpath, rest)
    }

    /// Tokenize the subpath into path components
    static func components(of subpath: String) throws(Error) -> [String] {
        guard !subpath.utf8.contains(0) else {
            throw Error.invalid(subpath: subpath, reason: "it contains a NUL byte")
        }
        let path = FilePath(subpath)
        guard !path.isAbsolute else {
            throw Error.invalid(subpath: subpath, reason: "it is absolute")
        }
        guard !path.components.contains(where: { $0.kind == .parentDirectory }) else {
            throw Error.invalid(subpath: subpath, reason: "it has a '..' component")
        }
        let names = path.components.filter { $0.kind == .regular }.map(\.string)
        guard !names.isEmpty else {
            throw Error.invalid(subpath: subpath, reason: "it is empty")
        }
        return names
    }

    #if os(Linux)
    /// The mode of the directories `open` creates for missing components.
    private static let directoryMode: mode_t = 0o755

    /// Open a subpath within the tree of a given rootFd, creating missing directories
    /// as root with `directoryMode`; pre-create the subpath for another owner or mode.
    ///
    /// Symlinks are followed, but one that leaves the volume fails with EXDEV (as it does in Kubernetes)
    public static func open(beneath rootFd: Int32, subpath: String) throws(Error) -> Int32 {
        let path = try components(of: subpath).joined(separator: "/")

        let fd = RootfsResolver.openInRoot(dirFd: rootFd, path: path, flags: RootfsResolver.oPath | O_CLOEXEC, confinement: RESOLVE_BENEATH)
        if fd >= 0 {
            return fd
        }
        guard errno == ENOENT else {
            throw .resolve(subpath: subpath, errno: errno)
        }

        let created: Int32
        do {
            created = try RootfsResolver.withDirectoryInRoot(dirFd: rootFd, path: path, perms: directoryMode, confinement: RESOLVE_BENEATH) { dup($0) }
        } catch let RootfsResolver.Error.errno(code, _) {
            throw .resolve(subpath: subpath, errno: code)
        } catch {
            // `withDirectoryInRoot` throws only `RootfsResolver.Error`.
            throw .resolve(subpath: subpath, errno: EIO)
        }
        guard created >= 0 else {
            throw .resolve(subpath: subpath, errno: errno)
        }
        return created
    }
    #endif
}
