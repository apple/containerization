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
let os_dup = Darwin.dup
#elseif canImport(Musl)
import CSystem
import Musl
let os_dup = Musl.dup
#elseif canImport(Glibc)
import Glibc
let os_dup = Glibc.dup
#endif

extension FileDescriptor {
    /// Creates a directory relative to the FileDescriptor, rejecting
    /// paths that traverse symlinks.
    ///
    /// - Parameters:
    ///   - relativePath: The path to the directory to create, relative to the FileDescriptor
    ///   - permissions: The permissions to give the directory (default is 0o755)
    ///   - makeIntermediates: Create or replace intermediate components as needed
    ///   - completion: A function that operates on the new directory
    /// - Throws: `SecurePathError` if path validation or system errors occur
    public func mkdirSecure(
        _ relativePath: FilePath,
        permissions: FilePermissions? = nil,
        makeIntermediates: Bool = false,
        completion: (FileDescriptor) throws -> Void = { _ in }
    ) throws {
        try Self.validateRelativePath(relativePath)
        try mkdirSecure(
            relativePath.components,
            permissions: permissions,
            makeIntermediates: makeIntermediates,
            completion: completion
        )
    }

    /// Recursively removes a direct child of a directory FileDescriptor.
    ///
    /// - Parameters:
    ///   - filename: The name of the child file
    /// - Throws: `SecurePathError` if system errors occur
    public func unlinkRecursiveSecure(filename: FilePath.Component) throws {
        guard filename.string != "." && filename.string != ".." else {
            return
        }

        // Try to remove as a file, and continue if the remove fails.
        guard unlinkat(self.rawValue, filename.string, 0) != 0 else {
            return
        }

        // Return if the file already doesn't exist.
        guard errno != ENOENT else {
            return
        }

        // If the file is not a directory, then throw a real error.
        guard errno == EPERM || errno == EISDIR else {
            throw SecurePathError.systemError("file removal during secure unlink", errno)
        }

        // Get the fd for the next path component.
        let componentFd = openat(self.rawValue, filename.string, O_NOFOLLOW | O_RDONLY | O_DIRECTORY)
        guard componentFd >= 0 else {
            throw SecurePathError.systemError("directory open during secure unlink", errno)
        }
        let componentFileDescriptor = FileDescriptor(rawValue: componentFd)
        defer { try? componentFileDescriptor.close() }

        // Open the directory stream using a duplicate fd that closedir() will close.
        let ownedFd = os_dup(componentFd)
        guard let dir = fdopendir(ownedFd) else {
            throw SecurePathError.systemError("directory opendir during secure unlink", errno)
        }
        defer { closedir(dir) }

        // Recurse into each directory entry.
        while let entry = readdir(dir) {
            let childComponent = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: Int(NAME_MAX) + 1) {
                    let name = String(decodingCString: $0, as: UTF8.self)
                    return FilePath.Component(name)
                }
            }
            guard let childComponent else {
                throw SecurePathError.systemError("directory entry processing during secure unlink", errno)
            }
            try componentFileDescriptor.unlinkRecursiveSecure(filename: childComponent)
        }

        // The current directory is empty now, remove it.
        if unlinkat(self.rawValue, filename.string, AT_REMOVEDIR) != 0 {
            throw SecurePathError.systemError("directory removal during secure unlink", errno)
        }
    }

    private func mkdirSecure(
        _ relativeComponents: FilePath.ComponentView,
        permissions: FilePermissions? = nil,
        makeIntermediates: Bool,
        completion: (FileDescriptor) throws -> Void
    ) throws {
        // If the relative path is empty, call completion with self (the parent directory)
        guard let currentComponent = relativeComponents.first else {
            try completion(self)
            return
        }
        let childComponents = FilePath.ComponentView(relativeComponents.dropFirst())

        // Create or replace the directory as needed.
        let parentFd = self.rawValue
        var componentFd = openat(parentFd, currentComponent.string, O_NOFOLLOW | O_RDONLY | O_DIRECTORY)
        if componentFd < 0 {
            // If the non-directory component should be replaced with a directory, remove the component.
            guard makeIntermediates || childComponents.isEmpty else {
                throw SecurePathError.invalidPathComponent
            }
            if errno != ENOENT {
                try self.unlinkRecursiveSecure(filename: currentComponent)
            }

            // Create and open an empty directory.
            guard mkdirat(parentFd, currentComponent.string, permissions?.rawValue ?? 0o755) == 0 else {
                throw SecurePathError.systemError("directory creation during secure mkdir", errno)
            }

            componentFd = openat(parentFd, currentComponent.string, O_NOFOLLOW | O_RDONLY | O_DIRECTORY)
            guard componentFd >= 0 else {
                throw SecurePathError.systemError("directory open during secure mkdir", errno)
            }
        }

        let componentFileDescriptor = FileDescriptor(rawValue: componentFd)
        defer { try? componentFileDescriptor.close() }

        // Call the completion closure for the last component.
        guard !childComponents.isEmpty else {
            try completion(componentFileDescriptor)
            return
        }

        // Create the directory for the remaining components.
        try componentFileDescriptor.mkdirSecure(childComponents, permissions: permissions, makeIntermediates: makeIntermediates, completion: completion)
    }

    private static func validateRelativePath(_ path: FilePath) throws {
        // Allow absolute paths; only the components will be used during traversal.
        guard !(path.components.contains { $0 == ".." }) else {
            throw SecurePathError.invalidRelativePath
        }
    }

    #if canImport(Darwin)
    public func getCanonicalPath() throws -> FilePath {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(self.rawValue, F_GETPATH, &buffer) != -1 else {
            throw Errno(rawValue: errno)
        }

        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let pathname = String(decoding: bytes, as: UTF8.self)
        return FilePath(pathname)
    }
    #elseif canImport(Glibc) || canImport(Musl)
    public func getCanonicalPath() throws -> FilePath {
        let fdPath = "/proc/self/fd/\(self.rawValue)"
        // Use readlink to resolve the symlink
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = readlink(fdPath, &buffer, buffer.count - 1)
        guard len > 0 else {
            throw SecurePathError.systemError("readlink", errno)
        }
        // Convert to bytes without null termination
        let bytes = buffer.prefix(len).map { UInt8(bitPattern: $0) }
        let pathname = String(decoding: bytes, as: UTF8.self)
        return FilePath(pathname)
    }
    #endif
}

public enum SecurePathError: Error, CustomStringConvertible, Equatable {
    case invalidRelativePath
    case invalidPathComponent
    case cannotFollowSymlink
    case systemError(String, Int32)

    public var description: String {
        switch self {
        case .invalidRelativePath:
            return "invalid relative path supplied to secure path operation"
        case .invalidPathComponent:
            return "an intermediate path component is missing or is not a directory"
        case .cannotFollowSymlink:
            return "cannot follow a symlink an a secure path operation"
        case .systemError(let operation, let err):
            return "\(operation) returned error: \(err)"
        }
    }
}
