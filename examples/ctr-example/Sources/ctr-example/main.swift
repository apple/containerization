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

import Containerization
import ContainerizationOS
import Foundation

@main
struct CtrExample {
    static func main() async throws {
        print("Starting container example...")

        // Set up terminal in raw mode (like cctl)
        let current = try Terminal.current
        try current.setraw()
        defer { current.tryReset() }

        let initfsReference = "ghcr.io/apple/containerization/vminit:0.13.0"
        let kernelPath = "./vmlinux"
        print("Fetching base container filesystem...")
        // Create container manager with file-based initfs
        var manager = try await ContainerManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
            initfsReference: initfsReference,
            network: try ContainerManager.VmnetNetwork()
        )

        let containerId = "ctr-example"
        let imageReference = "docker.io/library/alpine:3.16"

        print("Creating container from \(imageReference)...")

        // Create container with simple configuration
        let container = try await manager.create(
            containerId,
            reference: imageReference,
            rootfsSizeInBytes: 1.gib()
        ) { @Sendable config in
            config.cpus = 2
            config.memoryInBytes = 512.mib()
            config.process.setTerminalIO(terminal: current)
            config.process.arguments = ["/bin/sh"]
            config.process.workingDirectory = "/"
        }

        // Clean up on exit
        defer {
            try? manager.delete(containerId)
        }

        print("Starting container...")
        try await container.create()
        try await container.start()

        // Resize terminal to match current window
        try? await container.resize(to: try current.size)

        // Wait for container to finish
        let exitCode = try await container.wait()

        print("Container exited with code \(exitCode)")
        try await container.stop()
    }
}
