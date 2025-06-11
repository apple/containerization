//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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
import ContainerizationOCI
import ContainerizationOS
import Foundation

extension Application {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a container"
        )

        @Option(name: [.customLong("image"), .customShort("i")], help: "image reference to base the container on")
        var imageReference: String = "docker.io/library/alpine:3.16"

        @Option(name: .long, help: "id for the container")
        var id: String = "cctl"

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "Number of CPUs to allocate to the container")
        var cpus: Int = 2

        @Option(name: [.customLong("memory"), .customShort("m")], help: "Amount of memory in megabytes")
        var memory: UInt64 = 1024

        @Option(name: .customLong("fs-size"), help: "The size to create the block filesystem as")
        var fsSizeInMB: UInt64 = 2048

        @Option(name: .customLong("mount"), help: "directory to share into the container (Example: /foo:/bar)")
        var mounts: [String] = []

        @Option(name: .long, help: "ip address with subnet")
        var ip: String?

        @Option(name: .long, help: "gateway address")
        var gateway: String?

        @Option(name: .customLong("ns"), help: "nameserver addresses")
        var nameservers: [String] = []

        @Option(
            name: [.customLong("kernel"), .customShort("k")], help: "Kernel binary path", completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        public var kernel: String

        @Option(
            name: .customLong("init"), help: "Init block path", completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        public var initBlock: String

        @Option(name: .long, help: "Current working directory")
        var cwd: String = "/"

        @Argument var arguments: [String] = ["/bin/sh"]

        func run() async throws {
            let kernel = Kernel(
                path: URL(fileURLWithPath: kernel),
                platform: .linuxArm
            )
            let store = try await ContainerStore(
                root: Self.appRoot,
                kernel: kernel,
                initPath: .init(filePath: initBlock)
            )
            let sigwinch = setupSigwinchHandler()

            let current = try Terminal.current
            try current.setraw()
            defer { current.tryReset() }

            let container = try await store.create(
                id: id,
                reference: imageReference,
                fsSizeInBytes: fsSizeInMB.mib()
            )
            container.cpus = cpus
            container.memoryInBytes = memory.mib()

            container.terminalDevice = current
            container.arguments = arguments
            container.environment.append(contentsOf: [
                "HOME=/",
                "TERM=xterm",
            ])
            container.workingDirectory = cwd

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
                container.mounts.append(czMount)
            }

            if let ip {
                guard let gateway else {
                    throw ContainerizationError(.invalidArgument, message: "gateway must be specified")
                }
                container.interfaces.append(VZNATInterface(address: ip, gateway: gateway))
                container.dns = .init(nameservers: [gateway])
                if nameservers.count > 0 {
                    container.dns = .init(nameservers: nameservers)
                }
            }

            try await container.create()
            try await container.start()

            // Resize the containers pty to the current terminal window.
            try? await container.resize(to: try current.size)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in sigwinch {
                        try await container.resize(to: try current.size)
                    }
                }

                try await container.wait()
                group.cancelAll()

                try await container.stop()
            }
        }

        private func setupSigwinchHandler() -> AsyncStream<Void> {
            let sigwinch = DispatchSource.makeSignalSource(signal: SIGWINCH)
            let stream = AsyncStream<Void> { cont in
                sigwinch.setEventHandler {
                    cont.yield()
                }
            }
            sigwinch.resume()
            return stream
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
