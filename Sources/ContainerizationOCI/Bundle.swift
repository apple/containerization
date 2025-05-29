//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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

public struct Bundle: Sendable {
    public let path: URL

    public var configPath: URL {
        self.path.appending(path: "config.json")
    }

    public var rootfsPath: URL {
        self.path.appending(path: "rootfs")
    }

    public static func create(path: URL, spec: Data) throws -> Bundle {
        try self.init(path: path, spec: spec)
    }

    public static func create(path: URL, spec: ContainerizationOCI.Spec) throws -> Bundle {
        try self.init(path: path, spec: spec)
    }

    public static func load(path: URL) throws -> Bundle {
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

    private init(path: URL, spec: ContainerizationOCI.Spec) throws {
        self.path = path

        let fm = FileManager.default
        try fm.createDirectory(
            atPath: self.path.appending(component: "rootfs").path,
            withIntermediateDirectories: true
        )

        let specData = try JSONEncoder().encode(spec)
        try specData.write(to: self.configPath)
    }

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

    public func loadConfig() throws -> ContainerizationOCI.Spec {
        let data = try Data(contentsOf: self.configPath)
        return try JSONDecoder().decode(ContainerizationOCI.Spec.self, from: data)
    }
}
