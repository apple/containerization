//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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
import Foundation
import GRPC
import NIOCore
import NIOPosix

extension Application {
    struct FSNotify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fsnotify",
            abstract: "Send filesystem notification events to a running container"
        )

        @Option(name: [.customLong("container"), .customShort("c")], help: "Container ID to send notification to")
        var containerID: String

        @Option(name: [.customLong("path"), .customShort("p")], help: "Path in the container to notify about")
        var path: String

        @Option(name: [.customLong("event"), .customShort("e")], help: "Event type (create, delete, modify, link, unlink)")
        var eventType: String = "modify"

        @Option(name: .customLong("vsock-socket"), help: "Path to the container's VSock socket")
        var vsockSocket: String?

        @Option(name: .customLong("vsock-port"), help: "VSock port to connect to (default: 1024)")
        var vsockPort: UInt32 = 1024

        func run() async throws {
            let eventType = try parseEventType(eventType)

            print("Sending FSNotify event to container '\(containerID)':")
            print("  Path: \(path)")
            print("  Event: \(eventType)")

            guard let socket = vsockSocket else {
                print("Error: --vsock-socket parameter required")
                print("Usage: cctl fsnotify --container <id> --path <path> --vsock-socket <socket_path>")
                print("")
                print("Note: For end-to-end testing with real containers, use:")
                print("      cctl test --include 'fsnotify events'")
                throw ExitCode.failure
            }
            try await sendFSNotificationViaSocket(
                socket: socket,
                path: path,
                eventType: eventType
            )

            print("FSNotify event sent successfully")
        }

        private func parseEventType(_ eventString: String) throws -> Com_Apple_Containerization_Sandbox_V3_FileSystemEventType {
            switch eventString.lowercased() {
            case "create":
                return .create
            case "delete":
                return .delete
            case "modify":
                return .modify
            case "link":
                return .link
            case "unlink":
                return .unlink
            default:
                throw "Invalid event type '\(eventString)'. Valid options: create, delete, modify, link, unlink"
            }
        }

        private func sendFSNotificationViaSocket(
            socket: String,
            path: String,
            eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType
        ) async throws {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

            do {
                // Connect to the container's VSock socket
                let client = Vminitd.Client(socket: socket, group: group)
                let vminitd = Vminitd(client: client)

                // Send the notification using the public API
                let response = try await vminitd.notifyFileSystemEvent(
                    path: path,
                    eventType: eventType,
                    containerID: containerID
                )

                if !response.success {
                    let errorMsg = response.hasError ? response.error : "Unknown error"
                    throw "FSNotify failed: \(errorMsg)"
                }

                // Close the connection
                try await vminitd.close()

            } catch {
                // Ensure group is shutdown even if there's an error
                try await group.shutdownGracefully()
                throw error
            }

            // Shutdown the event loop group
            try await group.shutdownGracefully()
        }
    }
}
