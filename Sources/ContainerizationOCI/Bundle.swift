//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

import ContainerizationError
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

/// `Bundle` represents an OCI runtime spec bundle for running
/// a container.
public struct OCIBundle: Sendable {
    /// The path to the bundle.
    public let path: URL

    /// The path to the OCI runtime spec config.json file.
    public var configPath: URL {
        self.path.appending(path: "config.json")
    }

    /// The path to a rootfs mount inside the bundle.
    public var rootfsPath: URL {
        self.path.appending(path: "rootfs")
    }

    /// Create the OCI bundle.
    ///
    /// - Parameters:
    ///   - path: A URL pointing to where to create the bundle on the filesystem.
    ///   - spec: A data blob that should contain an OCI runtime spec. This will be written
    ///           to the bundle as a "config.json" file.
    public static func create(path: URL, spec: Data) throws -> OCIBundle {
        try self.init(path: path, spec: spec)
    }

    /// Create the OCI bundle.
    ///
    /// - Parameters:
    ///   - path: A URL pointing to where to create the bundle on the filesystem.
    ///   - spec: An OCI runtime spec that will be written to the bundle as a "config.json"
    ///           file.
    public static func create(path: URL, spec: OCISpec) throws -> OCIBundle {
        try self.init(path: path, spec: spec)
    }

    /// Load an OCI bundle from the provided path.
    ///
    /// - Parameters:
    ///   - path: A URL pointing to where to load the bundle from on the filesystem.
    public static func load(path: URL) throws -> OCIBundle {
        try self.init(path: path)
    }

    private init(path: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            throw ContainerizationError(.invalidArgument, message: "no bundle at \(path.path)")
        }
        self.path = path
    }

    // This constructor does not do any validation that data is actually a
    // valid OCI spec.
    private init(path: URL, spec: Data) throws {
        self.path = path

        let fm = FileManager.default
        try fm.createDirectory(
            atPath: self.path.appending(component: "rootfs").path,
            withIntermediateDirectories: true
        )

        try spec.write(to: self.configPath)
    }

    private init(path: URL, spec: OCISpec) throws {
        self.path = path

        let fm = FileManager.default
        try fm.createDirectory(
            atPath: self.path.appending(component: "rootfs").path,
            withIntermediateDirectories: true
        )

        let specData = try JSONEncoder().encode(spec)
        try specData.write(to: self.configPath)
    }

    /// Delete the OCI bundle from the filesystem.
    public func delete() throws {
        // Unmount, and then blow away the dir.
        #if os(Linux)
        let rootfs = self.rootfsPath.path
        guard _umount(rootfs, 0) == 0 else {
            throw POSIXError.fromErrno()
        }
        #endif
        // removeItem is recursive so should blow away the rootfs dir inside as well.
        let fm = FileManager.default
        try fm.removeItem(at: self.path)
    }

    /// Load and return the OCI runtime spec written to the bundle.
    public func loadConfig() throws -> OCISpec {
        let data = try Data(contentsOf: self.configPath)
        return try JSONDecoder().decode(OCISpec.self, from: data)
    }
}
