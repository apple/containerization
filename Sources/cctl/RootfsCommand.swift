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

import ArgumentParser
import Containerization
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation

extension Application {
    struct Rootfs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rootfs",
            abstract: "Manage the root filesystem for a container",
            subcommands: [
                Create.self
            ]
        )

        struct Create: AsyncParsableCommand {
            @Option(name: .long, help: "Path to vminitd")
            var vminitd: String

            @Option(name: .long, help: "Path to vmexec")
            var vmexec: String

            @Option(name: .long, help: "Platform of the built binaries being packaged into the block")
            var platformString: String = Platform.current.description

            @Option(name: .long, help: "Labels to add to the built image of the form <key1>=<value1>, [<key2>=<value2>,...]")
            var labels: [String] = []

            @Argument var rootfsPath: String

            @Argument var tag: String

            private static let directories = [
                "bin",
                "sbin",
                "dev",
                "sys",
                "proc/self",  // hack for swift init's booting
                "run",
                "tmp",
                "mnt",
                "var",
            ]

            func run() async throws {
                try await writeArchive()
                let p = try Platform(from: platformString)
                let rootfs = URL(filePath: rootfsPath)
                let labels = Application.parseKeyValuePairs(from: labels)
                _ = try await InitImage.create(
                    reference: tag, rootfs: rootfs,
                    platform: p, labels: labels,
                    imageStore: Application.imageStore,
                    contentStore: Application.contentStore)
            }

            private func writeArchive() async throws {
                let writer = try ArchiveWriter(format: .pax, filter: .gzip, file: URL(filePath: rootfsPath))
                let ts = Date()
                let entry = WriteEntry()
                entry.permissions = 0o755
                entry.modificationDate = ts
                entry.creationDate = ts
                entry.group = 0
                entry.owner = 0
                entry.fileType = .directory
                // create the initial directory structure.
                for dir in Self.directories {
                    entry.path = dir
                    try writer.writeEntry(entry: entry, data: nil)
                }

                entry.fileType = .regular
                entry.path = "sbin/vminitd"

                var src = URL(fileURLWithPath: vminitd)
                var data = try Data(contentsOf: src)
                entry.size = Int64(data.count)
                try writer.writeEntry(entry: entry, data: data)

                src = URL(fileURLWithPath: vmexec)
                data = try Data(contentsOf: src)
                entry.path = "sbin/vmexec"
                entry.size = Int64(data.count)
                try writer.writeEntry(entry: entry, data: data)

                entry.fileType = .symbolicLink
                entry.path = "proc/self/exe"
                entry.symlinkTarget = "sbin/vminitd"
                entry.size = nil
                try writer.writeEntry(entry: entry, data: data)
                try writer.finishEncoding()
            }
        }
    }
}
