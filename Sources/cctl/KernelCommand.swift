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
import Foundation

extension Application {
    struct KernelCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "kernel",
            abstract: "Manage kernel images",
            subcommands: [
                Create.self
            ]
        )

        struct Create: AsyncParsableCommand {
            @Option(name: .shortAndLong, help: "Name for the kernel image")
            var name: String

            @Option(name: .long, help: "Labels to add to the built image of the form <key1>=<value1>, [<key2>=<value2>,...]")
            var labels: [String] = []

            @Argument var kernels: [String]

            func run() async throws {
                let imageStore = Application.imageStore
                let contentStore = Application.contentStore
                let labels = Application.parseKeyValuePairs(from: labels)
                let binaries = try parseBinaries()
                _ = try await KernelImage.create(
                    reference: name,
                    binaries: binaries,
                    labels: labels,
                    imageStore: imageStore,
                    contentStore: contentStore
                )
            }

            func parseBinaries() throws -> [Kernel] {
                var binaries = [Kernel]()
                for rawBinary in kernels {
                    let parts = rawBinary.split(separator: ":")
                    guard parts.count == 2 else {
                        throw "invalid binary format: \(rawBinary)"
                    }
                    let platform: SystemPlatform
                    switch parts[1] {
                    case "arm64":
                        platform = .linuxArm
                    case "amd64":
                        platform = .linuxAmd
                    default:
                        fatalError("unsupported platform \(parts[1])")
                    }
                    binaries.append(
                        .init(
                            path: URL(fileURLWithPath: String(parts[0])),
                            platform: platform
                        )
                    )
                }
                return binaries
            }
        }
    }
}
