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
import ContainerizationOS
import Foundation
import NIOPosix

#if os(macOS)
extension Application {
    struct FSNotify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fsnotify",
            abstract: "Send a filesystem event notification to the guest"
        )

        @Option(help: "Container ID")
        var container: String

        @Option(help: "File path for the event")
        var path: String

        @Option(help: "Event type: create, modify, delete, link, unlink")
        var event: String = "create"

        @Option(name: .customLong("vsock-socket"), help: "Path to vsock socket")
        var vsockSocket: String?

        func run() async throws {
            let eventType: Vminitd.FileSystemEventType
            switch event.lowercased() {
            case "create":
                eventType = .create
            case "modify":
                eventType = .modify
            case "delete":
                eventType = .delete
            case "link":
                eventType = .link
            case "unlink":
                eventType = .unlink
            default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "unknown event type '\(event)', expected one of: create, modify, delete, link, unlink"
                )
            }

            guard let socketPath = vsockSocket else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "--vsock-socket is required"
                )
            }

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

            let socket = try Socket(type: UnixType(path: socketPath))
            try socket.connect()
            defer { try? socket.close() }
            let handle = FileHandle(fileDescriptor: socket.fileDescriptor, closeOnDealloc: false)

            let vminitd = try Vminitd(connection: handle, group: group)

            do {
                try await vminitd.notifyFileSystemEvent(
                    path: path,
                    eventType: eventType,
                    containerID: container
                )
                print("fsnotify: sent \(event) event for '\(path)' to container '\(container)'")
            } catch {
                print("fsnotify: failed to send event: \(error)")
                throw error
            }

            try? await vminitd.close()
            try? await group.shutdownGracefully()
        }
    }
}
#endif
