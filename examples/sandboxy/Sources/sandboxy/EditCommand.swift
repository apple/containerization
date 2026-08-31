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

import ArgumentParser
import Containerization
import ContainerizationExtras
import ContainerizationOS
import Foundation

extension Sandboxy {
    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Open an interactive shell in an agent's cached environment",
            discussion: """
                Boots the cached rootfs for the given agent and drops you into a shell.
                Any changes you make (installing packages, editing configs, etc.) are
                saved back to the cache when you exit. If no cache exists, the agent
                is installed from scratch first.
                """
        )

        @Argument(help: "Agent whose environment to edit (e.g. claude)")
        var agent: String

        @Option(
            name: [.customLong("kernel"), .customShort("k")],
            help: "Path to Linux kernel binary (auto-downloads if omitted)",
            completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory())
                    .absoluteURL.path(percentEncoded: false)
            })
        var kernel: String?

        func run() async throws {
            let config = try Sandboxy.loadConfig()

            let agents = AgentDefinition.allAgents(configRoot: Sandboxy.configRoot)
            guard let definition = agents[agent] else {
                let available = agents.keys.sorted().joined(separator: ", ")
                throw ValidationError(
                    "Unknown agent '\(agent)'. Available agents: \(available)"
                )
            }

            ProgressUI.printStatus("Opening \(definition.displayName) environment for editing...")

            let kernelPath = try await KernelManager.ensureKernel(
                explicitPath: kernel,
                appRoot: Sandboxy.appRoot,
                config: config
            )
            let vmKernel = Kernel(path: kernelPath, platform: .linuxArm)

            let enableNetworking: Bool
            var sharedNetwork: VmnetNetwork?
            if #available(macOS 26, *) {
                sharedNetwork = try VmnetNetwork()
                enableNetworking = true
            } else {
                sharedNetwork = nil
                enableNetworking = false
            }

            let vmnetMTU: UInt32 = 1400

            let initfsReference = config.initfsReference ?? SandboxyConfig.defaults.initfsReference!
            var manager = try await ContainerManager(
                kernel: vmKernel,
                initfsReference: initfsReference,
                root: Sandboxy.appRoot
            )

            let containerId = "\(agent)-edit-\(ProcessInfo.processInfo.processIdentifier)"

            let cacheDir = Sandboxy.appRoot.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let agentCachePath = cacheDir.appendingPathComponent("\(agent)-rootfs.ext4")
            let containerRootfsPath = Sandboxy.appRoot
                .appendingPathComponent("containers")
                .appendingPathComponent(containerId)
                .appendingPathComponent("rootfs.ext4")

            let hasCachedRootfs = FileManager.default.fileExists(
                atPath: agentCachePath.path(percentEncoded: false))

            let container: LinuxContainer

            if hasCachedRootfs {
                ProgressUI.printDetail("Using cached environment...")
                let containerDir = Sandboxy.appRoot
                    .appendingPathComponent("containers")
                    .appendingPathComponent(containerId)
                try FileManager.default.createDirectory(
                    at: containerDir, withIntermediateDirectories: true)

                let result = Darwin.clonefile(
                    agentCachePath.path(percentEncoded: false),
                    containerRootfsPath.path(percentEncoded: false),
                    0
                )
                if result != 0 {
                    try FileManager.default.copyItem(at: agentCachePath, to: containerRootfsPath)
                }

                let rootfsMount = Mount.block(
                    format: "ext4",
                    source: containerRootfsPath.path(percentEncoded: false),
                    destination: "/"
                )

                let image = try await Sandboxy.imageStore.get(
                    reference: definition.baseImage, pull: true)

                container = try await manager.create(
                    containerId,
                    image: image,
                    rootfs: rootfsMount,
                    networking: false
                ) { config in
                    if enableNetworking, let iface = try sharedNetwork?.createInterface(containerId, mtu: vmnetMTU) {
                        config.interfaces = [iface]
                        config.dns = .init(nameservers: [sharedNetwork!.ipv4Gateway.description])
                    }
                    config.cpus = 4
                    config.memoryInBytes = 4096 * 1024 * 1024
                    config.process.arguments = ["/bin/sleep", "infinity"]
                    config.process.workingDirectory = "/"
                    config.process.capabilities = .allCapabilities
                    config.useInit = true
                }
            } else {
                ProgressUI.printDetail("No cached environment, setting up from scratch...")
                container = try await manager.create(
                    containerId,
                    reference: definition.baseImage,
                    rootfsSizeInBytes: 512.gib(),
                    networking: false
                ) { config in
                    if enableNetworking, let iface = try sharedNetwork?.createInterface(containerId, mtu: vmnetMTU) {
                        config.interfaces = [iface]
                        config.dns = .init(nameservers: [sharedNetwork!.ipv4Gateway.description])
                    }
                    config.cpus = 4
                    config.memoryInBytes = 4096 * 1024 * 1024
                    config.process.arguments = ["/bin/sleep", "infinity"]
                    config.process.workingDirectory = "/"
                    config.process.capabilities = .allCapabilities
                    config.useInit = true
                }
            }

            do {
                try await container.create()
                try await container.start()

                // If no cache existed, run the agent's install commands first.
                if !hasCachedRootfs {
                    ProgressUI.printStatus("Installing \(definition.displayName) toolchain...")
                    do {
                        try await installAgent(in: container, definition: definition)
                        ProgressUI.printStatus("Installation complete.")
                    } catch {
                        ProgressUI.printError("Installation failed: \(error)")
                        ProgressUI.printStatus("Dropping into shell...")
                    }
                }

                // Drop into an interactive shell.
                ProgressUI.printStatus("Launching shell (exit to save changes)...\n")

                let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])
                let current = try Terminal.current
                try current.setraw()
                defer { current.tryReset() }

                let shellProcess = try await container.exec("edit-shell") { config in
                    config.arguments = ["/bin/bash"]
                    config.environmentVariables = [
                        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                        "TERM=xterm",
                        "HOME=/root",
                    ]
                    config.workingDirectory = "/root"
                    config.setTerminalIO(terminal: current)
                    config.capabilities = .allCapabilities
                }

                try await shellProcess.start()
                try? await shellProcess.resize(to: try current.size)

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in sigwinchStream.signals {
                            try await shellProcess.resize(to: try current.size)
                        }
                    }

                    _ = try await shellProcess.wait()
                    group.cancelAll()
                    try await shellProcess.delete()
                }

                // Stop container so rootfs is cleanly unmounted before caching.
                try await container.stop()

                // Save the modified rootfs back to the cache.
                ProgressUI.printStatus("Saving changes to cache...")
                removeIfExists(at: agentCachePath)
                try FileManager.default.copyItem(at: containerRootfsPath, to: agentCachePath)
                ProgressUI.printStatus("Done.")

                try manager.delete(containerId)
                try? sharedNetwork?.releaseInterface(containerId)
            } catch {
                do {
                    try await container.stop()
                } catch {
                    log.warning("Failed to stop container \(containerId): \(error)")
                }
                do {
                    try manager.delete(containerId)
                } catch {
                    log.warning("Failed to delete container \(containerId): \(error)")
                }
                try? sharedNetwork?.releaseInterface(containerId)
                throw error
            }
        }
    }
}
