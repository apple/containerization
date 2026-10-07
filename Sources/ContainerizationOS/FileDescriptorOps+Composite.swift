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

// Composite operations.
//
// These combine the primitives in `FileDescriptorOps.swift` into sequences that
// several callers need and that are easy to get wrong. They never follow a
// symlink, and their documentation says what, if anything, they replace.
//
// Only the primitives may be used here. Do not call system calls directly, so
// that every path walk goes through code that is written and tested once.

extension FileDescriptorOps {
    /// Opens, and where needed creates, the directory at `relativePath` below `fd`,
    /// then runs `completion` with a descriptor for it.
    ///
    /// Each component is opened relative to the previous one without following
    /// symlinks, so a symlink in the path can never redirect the walk. Existing
    /// directories are reused. The descriptor passed to `completion` is
    /// close-on-exec and is closed when `completion` returns.
    ///
    /// By default only the last component is created. Pass `makeIntermediates`
    /// to create missing parents too.
    ///
    /// **This replaces what is in the way.** A file, a symlink, or anything else that is not a
    /// directory, in the place of a directory this call needs, is removed and replaced by one. A
    /// symlink is removed and not followed. A directory is never removed, even one that cannot
    /// be opened.
    ///
    /// An empty `relativePath` runs `completion` with `fd` itself.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for the directory to start from.
    ///   - relativePath: The directory to open or create. It must be relative and must not contain a `..` component.
    ///   - permissions: The permissions for each directory this call creates (default 0o755).
    ///   - makeIntermediates: Also create missing intermediate directories.
    ///   - completion: A function that operates on the directory descriptor.
    /// - Throws: ``Error/invalidRelativePath`` for an absolute path or one containing `..`;
    ///   ``Error/invalidPathComponent`` if an intermediate component is missing, or is not a
    ///   directory, and `makeIntermediates` is false; and ``Error/systemError(_:_:)`` for anything
    ///   else. Errors thrown by `completion` are propagated.
    public static func mkdir(
        _ fd: FileDescriptor,
        _ relativePath: FilePath,
        permissions: FilePermissions? = nil,
        makeIntermediates: Bool = false,
        completion: (FileDescriptor) throws -> Void = { _ in }
    ) throws {
        try validateRelativePath(relativePath)

        let components = Array(relativePath.components)
        var current = fd
        var ownsCurrent = false
        defer {
            if ownsCurrent {
                try? current.close()
            }
        }

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let next = try openOrCreateDirectory(
                current,
                component,
                permissions: permissions,
                allowCreate: makeIntermediates || isLast
            )
            if ownsCurrent {
                try? current.close()
            }
            current = next
            ownsCurrent = true
        }

        try completion(current)
    }

    /// What to do when a symlink is found while resolving a path.
    public enum SymlinkPolicy: Sendable, Equatable {
        /// Refuse any symlink in the path, including the last component. This is the safe choice
        /// for anything that does not need symlinks to work.
        case refuse

        /// Follow a symlink, but only to a place beneath the directory the walk started from.
        ///
        /// Symlinks are resolved here, one component at a time, against directory descriptors
        /// that are already open, and never by the kernel. A relative target may use `..` as
        /// long as the result stays beneath the starting directory. An absolute target, a target
        /// that would leave the starting directory, and a chain of more than
        /// ``maximumSymlinksFollowed`` links are all refused as ``Error/cannotFollowSymlink``.
        ///
        /// Use it for trees that legitimately contain relative symlinks, such as a legacy
        /// docker-archive where a layer shared between images is a link to another image's copy.
        case followBeneath
    }

    /// The most symlinks that ``SymlinkPolicy/followBeneath`` follows while resolving one path.
    public static let maximumSymlinksFollowed = 40

    /// Opens the existing regular file at `relativePath` below `fd` for reading.
    ///
    /// Every component is opened relative to the previous one with `O_NOFOLLOW`, and the file is
    /// checked after it is open, so a swap of any component for a symlink while this runs
    /// cannot redirect the open. How symlinks that are already there are treated is up to `symlinks`.
    /// The returned descriptor is close-on-exec and the caller must close it.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for the directory to start from.
    ///   - relativePath: The file to open. It must be relative, must not contain a `..` component, and must name something.
    ///   - symlinks: What to do about symlinks in the path, including the last component. There is no default.
    /// - Throws: ``Error/invalidRelativePath`` for an absolute path, one containing `..`, or an empty path;
    ///   ``Error/notFound`` if the file or a parent does not exist; ``Error/cannotFollowSymlink`` if a symlink
    ///   is refused or cannot be followed beneath `fd`; ``Error/conflict(_:)`` if a parent is not a directory or
    ///   the path does not end at a regular file; and ``Error/systemError(_:_:)`` for anything else.
    public static func openFile(_ fd: FileDescriptor, relativePath: FilePath, symlinks: SymlinkPolicy) throws -> FileDescriptor {
        try validateRelativePath(relativePath)
        let components = Array(relativePath.components)
        guard !components.isEmpty else {
            throw Error.invalidRelativePath
        }
        return try resolveBeneath(
            fd, components, symlinks: symlinks,
            atEntry: { parent, name in try openFile(parent, name) },
            atDirectory: { _ in throw Error.conflict(.directory) })
    }

    /// Returns the metadata of the entry at `relativePath` below `fd`, or `nil` if the entry or
    /// one of its parents does not exist. An empty path describes `fd` itself.
    ///
    /// The entry itself is never followed: for a symlink this is the metadata of the link. How
    /// symlinks in the parent positions are treated is up to `symlinks`, so the answer always
    /// describes an entry that is really beneath `fd`.
    ///
    /// - Throws: ``Error/invalidRelativePath`` for an absolute path or one containing `..`;
    ///   ``Error/cannotFollowSymlink`` if a symlink in a parent position is refused or cannot be followed
    ///   beneath `fd`; ``Error/conflict(_:)`` if a parent is not a directory; and
    ///   ``Error/systemError(_:_:)`` for anything else.
    public static func status(_ fd: FileDescriptor, relativePath: FilePath, symlinks: SymlinkPolicy) throws -> FileStatus? {
        try validateRelativePath(relativePath)
        let components = Array(relativePath.components)
        guard !components.isEmpty else {
            return try status(of: fd)
        }
        do {
            return try resolveBeneath(
                fd, components, symlinks: symlinks,
                atEntry: { parent, name in try status(parent, name) },
                atDirectory: { directory in try status(of: directory) })
        } catch Error.notFound {
            return nil
        }
    }

    /// Walks `components` from `root`, opening each parent with `O_NOFOLLOW`, and calls `atEntry` with
    /// the directory that holds the last component. If `atEntry` throws ``Error/cannotFollowSymlink``
    /// because the last component is a symlink, and `symlinks` allows it, the link is followed.
    ///
    /// The walk keeps a stack of open directory descriptors. `..` in a symlink target pops the stack and is
    /// refused at the bottom, which is what keeps every followed link beneath `root`. If the path resolves
    /// to a directory without ever reaching a last component, for example a link to `..`, `atDirectory` runs.
    private static func resolveBeneath<T>(
        _ root: FileDescriptor,
        _ components: [FilePath.Component],
        symlinks: SymlinkPolicy,
        atEntry: (_ parent: FileDescriptor, _ name: FilePath.Component) throws -> T,
        atDirectory: (_ directory: FileDescriptor) throws -> T
    ) throws -> T {
        var pending = Array(components.reversed())
        var directories = [root]
        var symlinksFollowed = 0
        defer {
            // The first entry is the caller's descriptor.
            for directory in directories.dropFirst() {
                try? directory.close()
            }
        }

        func follow(_ name: FilePath.Component, in parent: FileDescriptor) throws {
            symlinksFollowed += 1
            guard symlinksFollowed <= maximumSymlinksFollowed else {
                throw Error.cannotFollowSymlink
            }
            let target = FilePath(try readSymlink(parent, name))
            guard !target.isAbsolute, !target.components.isEmpty else {
                throw Error.cannotFollowSymlink
            }
            // The target is resolved next, relative to the directory that holds the link.
            pending.append(contentsOf: target.components.reversed())
        }

        while let name = pending.popLast() {
            if name.string == "." {
                continue
            }
            if name.string == ".." {
                guard directories.count > 1, let popped = directories.popLast() else {
                    throw Error.cannotFollowSymlink
                }
                try? popped.close()
                continue
            }

            let parent = directories[directories.count - 1]
            do {
                if pending.isEmpty {
                    return try atEntry(parent, name)
                }
                directories.append(try openDirectory(parent, name))
            } catch Error.cannotFollowSymlink where symlinks == .followBeneath {
                try follow(name, in: parent)
            }
        }

        return try atDirectory(directories[directories.count - 1])
    }

    /// Writes the file `name` in `directory` so that a reader sees either the old contents or the new
    /// contents, never a partly written file.
    ///
    /// The new contents are written to a temporary file in the same directory, which is created
    /// exclusively, and then renamed over `name`. If `name` is a symlink, the link itself is replaced
    /// and its target is never written to. If `write` throws, the temporary file is removed and
    /// whatever was at `name` is left as it was.
    ///
    /// The new file does not inherit the permissions or ownership of the file it replaces. It
    /// is atomic with respect to other readers, but it does not flush to disk.
    ///
    /// - Parameters:
    ///   - directory: An open file descriptor for the directory that holds the file.
    ///   - name: The name of the file to write.
    ///   - permissions: The permissions to give the new file (default 0o644), subject to the umask.
    ///   - write: Writes the new contents to the descriptor it is given. It must not close the descriptor.
    /// - Throws: Errors from `write`, and ``Error/systemError(_:_:)`` if the temporary file cannot be
    ///   created or renamed into place, for example because `name` is a non-empty directory.
    public static func replaceFile(
        in directory: FileDescriptor,
        named name: FilePath.Component,
        permissions: FilePermissions? = nil,
        write: (FileDescriptor) throws -> Void
    ) throws {
        guard let temporaryName = FilePath.Component(".tmp-" + String(UInt64.random(in: .min ... .max), radix: 16)) else {
            throw Error.invalidPathComponent
        }

        let file = try createFile(directory, temporaryName, permissions: permissions)
        var isOpen = true
        do {
            try write(file)
            isOpen = false
            try file.close()
            try rename(directory, temporaryName, to: directory, name)
        } catch {
            if isOpen {
                try? file.close()
            }
            try? unlink(directory, temporaryName)
            throw error
        }
    }

    private static func openOrCreateDirectory(
        _ parent: FileDescriptor,
        _ name: FilePath.Component,
        permissions: FilePermissions?,
        allowCreate: Bool
    ) throws -> FileDescriptor {
        do {
            return try openDirectory(parent, name)
        } catch let error as Error {
            switch error {
            case .notFound:
                guard allowCreate else {
                    throw Error.invalidPathComponent
                }
            case .cannotFollowSymlink, .conflict:
                // Something that is not a directory is in the way. Replace it. This removes a symlink
                // and not its target, and it never removes a directory.
                guard allowCreate else {
                    throw Error.invalidPathComponent
                }
                try unlink(parent, name)
            default:
                throw error
            }
        }

        try makeDirectory(parent, name, permissions: permissions)
        return try openDirectory(parent, name)
    }
}
