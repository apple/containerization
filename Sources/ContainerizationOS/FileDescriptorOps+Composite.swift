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

    /// Opens the existing regular file at `relativePath` below `fd` for reading.
    ///
    /// Every component is opened relative to the previous one without following
    /// symlinks, and the file is checked after it is open. A symlink anywhere in the
    /// path, including the last component, is refused, and a swap of any component
    /// for a symlink while this runs cannot redirect the open. The returned descriptor
    /// is close-on-exec and the caller must close it.
    ///
    /// - Parameters:
    ///   - fd: An open file descriptor for the directory to start from.
    ///   - relativePath: The file to open. It must be relative, must not contain a `..` component, and must name something.
    /// - Throws: ``Error/invalidRelativePath`` for an absolute path, one containing `..`, or an empty path;
    ///   ``Error/notFound`` if the file or a parent does not exist; ``Error/cannotFollowSymlink`` if a symlink
    ///   is in the path; ``Error/conflict(_:)`` if a parent is not a directory or the file is not a regular
    ///   file; and ``Error/systemError(_:_:)`` for anything else.
    public static func openFile(_ fd: FileDescriptor, relativePath: FilePath) throws -> FileDescriptor {
        try validateRelativePath(relativePath)
        var components = Array(relativePath.components)
        guard let name = components.popLast() else {
            throw Error.invalidRelativePath
        }
        return try withDirectory(fd, components) { parent in
            try openFile(parent, name)
        }
    }

    /// Returns the metadata of the entry at `relativePath` below `fd`, without following
    /// symlinks, or `nil` if the entry or one of its parents does not exist. For a symlink this
    /// is the metadata of the link itself. An empty path describes `fd` itself.
    ///
    /// A symlink in a parent position is refused, so the answer always describes an entry
    /// that is really beneath `fd`.
    ///
    /// - Throws: ``Error/invalidRelativePath`` for an absolute path or one containing `..`;
    ///   ``Error/cannotFollowSymlink`` if a symlink is in a parent position; ``Error/conflict(_:)`` if a
    ///   parent is not a directory; and ``Error/systemError(_:_:)`` for anything else.
    public static func status(_ fd: FileDescriptor, relativePath: FilePath) throws -> FileStatus? {
        try validateRelativePath(relativePath)
        var components = Array(relativePath.components)
        guard let name = components.popLast() else {
            return try status(of: fd)
        }
        do {
            return try withDirectory(fd, components) { parent in
                try status(parent, name)
            }
        } catch Error.notFound {
            return nil
        }
    }

    /// Runs `body` with a descriptor for the directory reached by walking `components` from
    /// `fd`, without following symlinks. With no components, `body` gets `fd` itself.
    private static func withDirectory<T>(
        _ fd: FileDescriptor,
        _ components: [FilePath.Component],
        _ body: (FileDescriptor) throws -> T
    ) throws -> T {
        var current = fd
        var ownsCurrent = false
        defer {
            if ownsCurrent {
                try? current.close()
            }
        }

        for component in components {
            let next = try openDirectory(current, component)
            if ownsCurrent {
                try? current.close()
            }
            current = next
            ownsCurrent = true
        }

        return try body(current)
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
