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
            @Option(name: [.short, .customLong("add-file")], help: "Additional file to add (format src-path:dst-path)")
            var addFiles: [String] = []

            @Option(name: .customLong("ext4"), help: "The path to an ext4 image to create.")
            var ext4File: String?

            @Option(name: .customLong("image"), help: "The name of the image to produce.")
            var imageName: String?

            @Option(name: .customLong("label"), help: "Label to add to the image (format: key=value)")
            var labels: [String] = []

            @Option(name: .long, help: "Platform of the built binaries being packaged into the block")
            var platformString: String = Platform.current.description

            @Option(name: .long, help: "Path to vmexec")
            var vmexec: String

            @Option(name: .long, help: "Path to vminitd")
            var vminitd: String

            @Option(name: .long, help: "Path to OCI runtime")
            var ociRuntime: String?

            // The path where the intermediate tar archive is created.
            @Argument var tarPath: String

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
                let path = URL(filePath: self.tarPath)
                try await writeArchive(path: path)

                if let image = self.imageName {
                    print("creating initfs image \(image)...")
                    try await outputImage(
                        path: path,
                        reference: image
                    )
                }

                if let ext4Path = self.ext4File {
                    print("creating initfs ext4 image at \(ext4Path)...")
                    try await outputExt4(
                        archive: path,
                        to: URL(filePath: ext4Path)
                    )
                }
            }

            private func outputExt4(archive: URL, to path: URL) async throws {
                let unpacker = EXT4Unpacker(blockSizeInBytes: 256.mib())
                try unpacker.unpack(archive: archive, compression: .gzip, at: path)
            }

            private func outputImage(path: URL, reference: String) async throws {
                let p = try Platform(from: platformString)
                let parsedLabels = Application.parseKeyValuePairs(from: labels)
                _ = try await InitImage.create(
                    reference: reference,
                    rootfs: path,
                    platform: p,
                    labels: parsedLabels,
                    imageStore: Application.imageStore,
                    contentStore: Application.contentStore
                )
            }

            private func writeArchive(path: URL) async throws {
                let writer = try ArchiveWriter(
                    format: .pax,
                    filter: .gzip,
                    file: path,
                )
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

                if let ociRuntimePath = self.ociRuntime {
                    src = URL(fileURLWithPath: ociRuntimePath)
                    let fileName = src.lastPathComponent
                    data = try Data(contentsOf: src)
                    entry.path = "sbin/\(fileName)"
                    entry.size = Int64(data.count)
                    try writer.writeEntry(entry: entry, data: data)
                }

                for addFile in addFiles {
                    let paths = addFile.components(separatedBy: ":")
                    guard paths.count == 2 else {
                        throw ContainerizationError(.invalidArgument, message: "use src-path:dst-path for --add-file")
                    }
                    src = URL(fileURLWithPath: paths[0])
                    data = try Data(contentsOf: src)
                    entry.path = paths[1]
                    entry.size = Int64(data.count)
                    try writer.writeEntry(entry: entry, data: data)
                }

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
