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
    /// Optionally provide `createWithPerms` to set the permissions for the directory that
    /// it will be mounted at.
    public func mount(root: String, createWithPerms: Int16? = nil) throws {
        var rootURL = URL(fileURLWithPath: root)
        rootURL = rootURL.resolvingSymlinksInPath()
        rootURL = rootURL.appendingPathComponent(self.target)
        try self.mountToTarget(target: rootURL.path, createWithPerms: createWithPerms)
    }

    /// Mount the mount with the current set of data in the object. Optionally
    /// provide `createWithPerms` to set the permissions for the directory that
    /// it will be mounted at.
    public func mount(createWithPerms: Int16? = nil) throws {
        try self.mountToTarget(target: self.target, createWithPerms: createWithPerms)
    }

    private func mountToTarget(target: String, createWithPerms: Int16?) throws {
        let pageSize = sysconf(Int32(_SC_PAGESIZE))

        let opts = parseMountOptions()
        let dataString = opts.data.joined(separator: ",")
        if dataString.count > pageSize {
            throw Error.validation("data string exceeds page size (\(dataString.count) > \(pageSize))")
        }

        let propagationTypes: Int32 = Int32(MS_SHARED) | Int32(MS_PRIVATE) | Int32(MS_SLAVE) | Int32(MS_UNBINDABLE)

        // Ensure propagation type change flags aren't included in other calls.
        let originalFlags = opts.flags & ~(propagationTypes)

        let targetURL = URL(fileURLWithPath: self.target)
        let targetParent = targetURL.deletingLastPathComponent().path
        if let perms = createWithPerms {
            try mkdirAll(targetParent, perms)
        }
        try mkdirAll(target, 0o755)

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
