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
import ContainerizationOCI
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
            static let configuration = CommandConfiguration(
                commandName: "create",
                abstract: "Create an init image from a prebuilt rootfs tar archive"
            )

            @Option(name: .customLong("image"), help: "The name of the image to produce.")
            var imageName: String

            @Option(name: .customLong("label"), help: "Label to add to the image (format: key=value)")
            var labels: [String] = []

            @Option(name: .long, help: "Platform of the binaries packaged into the rootfs")
            var platformString: String = Platform.current.description

            // The gzip-compressed rootfs tar archive whose contents make up the
            // image layer — e.g. produced by `scripts/build-initfs.sh --tar`,
            // which also builds the matching initfs.ext4. The rootfs layout is
            // owned by that script; this command only wraps it into an image.
            @Argument(help: "Path to the gzip-compressed rootfs tar archive")
            var rootfs: String

            func run() async throws {
                let platform = try Platform(from: platformString)
                let parsedLabels = Application.parseKeyValuePairs(from: labels)
                print("creating initfs image \(imageName)...")
                _ = try await InitImage.create(
                    reference: imageName,
                    rootfs: URL(filePath: rootfs),
                    platform: platform,
                    labels: parsedLabels,
                    imageStore: Application.imageStore,
                    contentStore: Application.contentStore
                )
            }
        }
    }
}
