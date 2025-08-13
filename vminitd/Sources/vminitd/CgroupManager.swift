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

import ContainerizationOS
import Foundation
import Logging
import Musl

enum Cgroup2Controller: String {
    case pids
    case memory
    case cpuset
    case cpu
    case io
    case hugetlb
}

// Extremely simple cgroup manager. Our needs are simple for now, and this is
// reflected in the type.
internal struct Cgroup2Manager {
    static let defaultMountPoint = URL(filePath: "/sys/fs/cgroup")

    static let killFile = "cgroup.kill"
    static let procsFile = "cgroup.procs"
    static let subtreeControlFile = "cgroup.subtree_control"

    private let mountPoint: URL
    private let path: URL
    private let logger: Logger?

    init(
        mountPoint: URL = defaultMountPoint,
        path: URL,
        perms: Int16 = 0o755,
        logger: Logger? = nil
    ) throws {
        self.mountPoint = mountPoint
        self.path = mountPoint.appending(path: path.path)
        self.logger = logger

        self.logger?.error(
            "creating cgroup manager",
            metadata: [
                "mountpoint": "\(self.mountPoint.path)",
                "path": "\(self.path.path)",
            ])

        try FileManager.default.createDirectory(
            at: self.path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: perms]
        )
    }

    private static func writeValue(path: URL, value: String, fileName: String) throws {
        let file = path.appending(path: fileName)
        let fd = open(file.path, O_WRONLY, 0)
        if fd == -1 {
            throw Error.errno(errno: errno, message: "failed to open \(file.path)")
        }
        defer { close(fd) }

        let bytes = Array(value.utf8)
        let res = Syscall.retrying {
            bytes.withUnsafeBytes { write(fd, $0.baseAddress!, bytes.count) }
        }
        if res == -1 {
            throw Error.errno(errno: errno, message: "failed to write to \(file.path)")
        }
    }

    func toggleSubtreeControllers(controllers: [Cgroup2Controller], enable: Bool) throws {
        let value = controllers.map { (enable ? "+" : "-") + $0.rawValue }.joined(separator: " ")
        let mountComponents = self.mountPoint.pathComponents
        let pathComponents = self.path.pathComponents

        // First ensure it's set on the root.
        var current = self.mountPoint
        try Self.writeValue(
            path: current,
            value: value,
            fileName: Self.subtreeControlFile
        )

        // Toggle everything except the leaf, as otherwise we won't be able to write
        // to cgroup.procs, and what fun is that :)
        if mountComponents.count < pathComponents.count - 1 {
            for i in mountComponents.count...pathComponents.count - 2 {
                current = current.appending(path: pathComponents[i])
                try Self.writeValue(
                    path: current,
                    value: value,
                    fileName: Self.subtreeControlFile
                )
            }
        }
    }

    func addProcess(pid: Int32) throws {
        let pidStr = String(pid)
        try Self.writeValue(
            path: self.path,
            value: pidStr,
            fileName: Self.procsFile
        )
    }

    func kill() throws {
        try Self.writeValue(
            path: self.path,
            value: "1",
            fileName: Self.killFile
        )
    }

    func delete(force: Bool = false) throws {
        if force {
            try self.kill()
        }
        try FileManager.default.removeItem(at: self.path)
    }
}

extension Cgroup2Manager {
    enum Error: Swift.Error, CustomStringConvertible {
        case errno(errno: Int32, message: String)

        var description: String {
            switch self {
            case .errno(let errno, let message):
                return "failed with errno \(errno): \(message)"
            }
        }
    }
}
