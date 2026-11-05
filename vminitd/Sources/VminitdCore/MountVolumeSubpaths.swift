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

import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Stages the subpath mounts of a spec for runc. Each subpath is resolved
/// inside its volume and bound by descriptor to an agent-owned path, so runc
/// never resolves a path that a container sharing the volume can change.
enum MountVolumeSubpaths {
    private static let defaultRoot = URL(fileURLWithPath: "/run/container-subpaths")

    /// Stages every subpath mount of `spec` and rewrites those mounts.
    /// A spec without a subpath mount is unchanged and creates nothing.
    /// On an error the mounts staged so far are removed.
    static func stage(
        id: String,
        spec: inout ContainerizationOCI.Spec,
        root: URL = defaultRoot,
        log: Logger
    ) throws {
        let hasSubpath = try spec.mounts.contains {
            try VolumeSubpath.isSubpathMount(options: $0.options)
        }
        guard hasSubpath else {
            return
        }

        let dir = root.appending(path: id)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var staged = 0
            spec.mounts = try spec.mounts.map { mount in
                guard try VolumeSubpath.isSubpathMount(options: mount.options) else {
                    return mount
                }

                defer { staged += 1 }
                return try stageMount(mount, target: dir.appending(path: String(staged)).path, log: log)
            }
        } catch {
            remove(id: id, root: root, log: log)
            throw error
        }
    }

    /// Binds the subpath of `mount` at `target` and returns `mount` sourced from it.
    private static func stageMount(_ mount: ContainerizationOCI.Mount, target: String, log: Logger) throws -> ContainerizationOCI.Mount {
        let (subpath, options) = try VolumeSubpath.extract(from: mount.options)
        try bindSubpath(source: mount.source, subpath: subpath, target: target)
        log.debug(
            "staged subpath mount",
            metadata: [
                "source": "\(mount.source)",
                "subpath": "\(subpath)",
                "staging": "\(target)",
                "destination": "\(mount.destination)",
            ])

        var staged = mount
        staged.source = target
        staged.options = options
        return staged
    }

    private static func bindSubpath(
        source: String,
        subpath: String,
        target: String
    ) throws {
        let rootFd = open(source, RootfsResolver.oPath | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else {
            let code = errno
            throw ContainerizationError(
                .notFound,
                message: "subpath '\(subpath)': cannot open the mount source \(source): \(String(cString: strerror(code)))"
            )
        }
        defer { close(rootFd) }

        let fd: Int32
        do {
            fd = try VolumeSubpath.open(beneath: rootFd, subpath: subpath)
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "mount source \(source): \(error)"
            )
        }
        defer { close(fd) }

        // `/proc/self/fd/N` binds the opened object itself, so a later rename or symlink swap cannot redirect it.
        let staging = ContainerizationOS.Mount(type: "none", source: "/proc/self/fd/\(fd)", target: target, options: ["bind"])
        do {
            try staging.mount()
        } catch {
            throw ContainerizationError(.internalError, message: "bind subpath '\(subpath)' at \(target): \(error)")
        }
    }

    /// Detaches and deletes the staging mounts of container `id`.
    /// It deletes only the mount points and the container's staging directory, never
    /// recursively, so a mount that stays attached keeps its data.
    static func remove(
        id: String,
        root: URL = defaultRoot,
        log: Logger
    ) {
        let dir = root.appending(path: id).path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return
        }
        for name in names {
            let path = dir + "/" + name
            // A path that is not a mount point is not an error.
            _ = umount2(path, Int32(MNT_DETACH))
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let rc = (st.st_mode & S_IFMT) == S_IFDIR ? rmdir(path) : unlink(path)
            if rc != 0 {
                let code = errno
                log.error("cannot remove subpath staging \(path): \(String(cString: strerror(code)))")
            }
        }
        if rmdir(dir) != 0 {
            let code = errno
            log.error("cannot remove subpath staging directory \(dir): \(String(cString: strerror(code)))")
        }
    }
}

#endif
