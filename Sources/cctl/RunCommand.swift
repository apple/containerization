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
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation

extension Application {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a container"
        )

        @Option(name: [.customLong("image"), .customShort("i")], help: "Image reference to base the container on")
        var imageReference: String = "docker.io/library/alpine:3.16"

        @Option(name: .long, help: "id for the container")
        var id: String = "cctl"

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "Number of CPUs to allocate to the container")
        var cpus: Int = 2

        @Option(name: [.customLong("memory"), .customShort("m")], help: "Amount of memory in megabytes")
        var memory: UInt64 = 1024

        @Option(name: .customLong("fs-size"), help: "The size to create the block filesystem as")
        var fsSizeInMB: UInt64 = 2048

        @Flag(name: .customLong("rosetta"), help: "Enable rosetta x64 emulation")
        var rosetta = false

        @Option(name: .customLong("mount"), help: "Directory to share into the container (Example: /foo:/bar)")
        var mounts: [String] = []

        @Option(name: .long, help: "IP address with subnet")
        var ip: String?

        @Option(name: .long, help: "Gateway address")
        var gateway: String?

        @Option(name: .customLong("ns"), help: "Nameserver addresses")
        var nameservers: [String] = []

        @Option(name: .long, help: "Path to OCI runtime to use for spawning the container")
        var ociRuntimePath: String?

        @Flag(name: .long, help: "Make rootfs readonly")
        var readOnly: Bool = false

        @Option(
            name: [.customLong("kernel"), .customShort("k")], help: "Kernel binary path", completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        public var kernel: String

        @Option(name: .long, help: "Current working directory")
        var cwd: String = "/"

        @Argument(parsing: .captureForPassthrough)
        var arguments: [String] = ["/bin/sh"]

        func run() async throws {
            let kernel = Kernel(
                path: URL(fileURLWithPath: kernel),
                platform: .linuxArm
            )
            var manager = try await ContainerManager(
                kernel: kernel,
                initfsReference: "vminit:latest",
                rosetta: rosetta
            )
            let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])

            let current = try Terminal.current
            try current.setraw()
            defer { current.tryReset() }

            let container = try await manager.create(
                id,
                reference: imageReference,
                rootfsSizeInBytes: fsSizeInMB.mib(),
                readOnly: readOnly
            ) { config in
                config.cpus = cpus
                config.memoryInBytes = memory.mib()
                config.process.setTerminalIO(terminal: current)
                config.process.arguments = arguments
                config.process.workingDirectory = cwd
                config.process.capabilities = .allCapabilities

                for mount in self.mounts {
                    let paths = mount.split(separator: ":")
                    if paths.count != 2 {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "incorrect mount format detected: \(mount)"
                        )
                    }
                    let host = String(paths[0])
                    let guest = String(paths[1])
                    let czMount = Containerization.Mount.share(
                        source: host,
                        destination: guest
                    )
                    config.mounts.append(czMount)
                }

                var hosts = Hosts.default
                if let ip {
                    guard let gateway else {
                        throw ContainerizationError(.invalidArgument, message: "gateway must be specified")
                    }
                    let ipv4Address = try CIDRv4(ip)
                    let ipv4Gateway = try IPv4Address(gateway)
                    config.interfaces.append(NATInterface(ipv4Address: ipv4Address, ipv4Gateway: ipv4Gateway))
                    config.dns = .init(nameservers: [gateway])
                    if nameservers.count > 0 {
                        config.dns = .init(nameservers: nameservers)
                    }
                    hosts.entries.append(
                        Hosts.Entry(
                            ipAddress: ip,
                            hostnames: [id]
                        ))
                }
                config.hosts = hosts
                if let ociRuntimePath {
                    config.ociRuntimePath = ociRuntimePath
                    config.mounts = LinuxContainer.defaultOCIMounts()
                }
            }

            defer {
                try? manager.delete(id)
            }

            try await container.create()
            try await container.start()

            // Resize the containers pty to the current terminal window.
            try? await container.resize(to: try current.size)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in sigwinchStream.signals {
                        try await container.resize(to: try current.size)
                    }
                }

                try await container.wait()
                group.cancelAll()

                try await container.stop()
            }
        }

        private static let appRoot: URL = {
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            .appendingPathComponent("com.apple.containerization")
        }()
    }
}
