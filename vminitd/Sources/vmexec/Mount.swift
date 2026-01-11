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

import ContainerizationOCI
import ContainerizationOS
import Foundation
import Musl

struct ContainerMount {
    private let mounts: [ContainerizationOCI.Mount]
    private let rootfs: String

    init(rootfs: String, mounts: [ContainerizationOCI.Mount]) {
        self.rootfs = rootfs
        self.mounts = mounts
    }

    func mountToRootfs() throws {
        for m in self.mounts {
            let osMount = m.toOSMount()
            try osMount.mount(root: self.rootfs)
        }
    }

    func configureConsole() throws {
        let ptmx = self.rootfs.standardizingPath.appendingPathComponent("dev/ptmx")
        guard remove(ptmx) == 0 else {
            throw App.Errno(stage: "remove(ptmx)")
        }
        guard symlink("pts/ptmx", ptmx) == 0 else {
            throw App.Errno(stage: "symlink(pts/ptmx)")
        }
    }

    private func mkdirAll(_ name: String, _ perm: Int16) throws {
        try FileManager.default.createDirectory(
            atPath: name,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: perm]
        )
    }
}

extension ContainerizationOCI.Mount {
    func toOSMount() -> ContainerizationOS.Mount {
        ContainerizationOS.Mount(
            type: self.type,
            source: self.source,
            target: self.destination,
            options: self.options
        )
    }
}
