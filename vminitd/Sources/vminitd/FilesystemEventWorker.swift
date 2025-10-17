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

import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import NIOCore
import NIOPosix
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

typealias FileSystemEventType = Com_Apple_Containerization_Sandbox_V3_FileSystemEventType

final class FilesystemEventWorker: Sendable {
    private static let handshakeReady: UInt8 = 0xAA
    private static let handshakeFailure: UInt8 = 0xFF

    private let containerID: String
    private let containerPID: Int32
    private let eventLoop: EventLoop
    private let log: Logger

    // Cross-thread state (synchronized via Mutex)
    private struct State {
        var childPID: Int32?
        var isStopped: Bool = false
        var channel: Channel?
    }
    private let state: Mutex<State> = Mutex(State(childPID: nil, isStopped: false))

    init(containerID: String, containerPID: Int32, eventLoop: EventLoop, log: Logger) {
        self.containerID = containerID
        self.containerPID = containerPID
        self.eventLoop = eventLoop
        self.log = log
    }

    func start() throws {
        guard state.withLock({ $0.childPID }) == nil else {
            throw ContainerizationError(.invalidState, message: "FilesystemEventWorker already started")
        }

        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw ContainerizationError(.internalError, message: "Failed to create socketpair: errno \(errno)")
        }

        let parentSocket = sockets[0]
        let childSocket = sockets[1]

        var errorPipe: [Int32] = [0, 0]
        guard pipe(&errorPipe) == 0 else {
            close(parentSocket)
            close(childSocket)
            throw ContainerizationError(.internalError, message: "Failed to create error pipe: errno \(errno)")
        }
        let errorReadFD = errorPipe[0]
        let errorWriteFD = errorPipe[1]

        // Use Command to exec vminitd fs-notify subcommand (fork+execve)
        // Socket is FD 3 (extraFiles[0]), error pipe is FD 4 (extraFiles[1])
        var command = Command("/sbin/vminitd", arguments: ["fs-notify", String(containerPID)])
        command.extraFiles = [
            FileHandle(fileDescriptor: childSocket, closeOnDealloc: false),
            FileHandle(fileDescriptor: errorWriteFD, closeOnDealloc: false),
        ]
        command.stdin = .standardInput
        command.stdout = .standardOutput
        command.stderr = .standardError

        do {
            try command.start()
        } catch {
            close(parentSocket)
            close(childSocket)
            close(errorReadFD)
            close(errorWriteFD)
            throw ContainerizationError(.internalError, message: "Failed to start fs-notify process: \(error)")
        }

        let pid = command.pid
        close(childSocket)
        close(errorWriteFD)  // Close write end in parent
        state.withLock {
            $0.childPID = pid
        }

        var handshake: UInt8 = 0
        let readResult = read(parentSocket, &handshake, 1)

        if readResult != 1 {
            close(parentSocket)
            close(errorReadFD)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            state.withLock { $0.childPID = nil }
            throw ContainerizationError(.internalError, message: "Child process failed to start")
        }

        if handshake == Self.handshakeFailure {
            close(parentSocket)

            // Read error message from child
            var errorBuffer = [UInt8](repeating: 0, count: 1024)
            let bytesRead = read(errorReadFD, &errorBuffer, errorBuffer.count)
            close(errorReadFD)

            var status: Int32 = 0
            waitpid(pid, &status, 0)
            state.withLock { $0.childPID = nil }

            let errorMsg =
                bytesRead > 0
                ? (String(bytes: errorBuffer.prefix(bytesRead), encoding: .utf8) ?? "unknown error")
                : "no error message"
            throw ContainerizationError(.internalError, message: "Child process failed: \(errorMsg)")
        }

        if handshake != Self.handshakeReady {
            close(parentSocket)
            close(errorReadFD)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            state.withLock { $0.childPID = nil }
            throw ContainerizationError(.internalError, message: "Child process sent unexpected handshake: \(handshake)")
        }

        // Success - close error pipe
        close(errorReadFD)

        do {
            let eventChannel = try NIOPipeBootstrap(group: eventLoop)
                .takingOwnershipOfDescriptor(inputOutput: parentSocket)
                .wait()

            state.withLock { state in
                state.channel = eventChannel
            }
        } catch {
            close(parentSocket)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            state.withLock { $0.childPID = nil }
            throw ContainerizationError(.internalError, message: "Failed to setup NIO channel: \(error)")
        }
    }

    func enqueueEvent(path: String, eventType: FileSystemEventType) throws {
        guard !state.withLock({ $0.isStopped }) else {
            throw ContainerizationError(.invalidState, message: "FilesystemEventWorker not running")
        }

        eventLoop.execute {
            let channel = self.state.withLock { $0.channel }
            guard let channel = channel else { return }

            // Build ByteBuffer with binary protocol:
            // [event_type:4 bytes][path_len:4 bytes][path:N bytes]
            let pathUTF8Count = path.utf8.count
            var buffer = channel.allocator.buffer(capacity: 8 + pathUTF8Count)
            buffer.writeInteger(UInt32(eventType.rawValue), endianness: .big)
            buffer.writeInteger(UInt32(pathUTF8Count), endianness: .big)
            buffer.writeString(path)

            channel.writeAndFlush(buffer).whenFailure { error in
                self.log.warning(
                    "Failed to send event to fs-notify child",
                    metadata: [
                        "container": "\(self.containerID)",
                        "path": "\(path)",
                        "error": "\(error)",
                    ])
            }
        }
    }

    func stop() {
        eventLoop.execute {
            self.state.withLock { state in
                state.channel?.close(promise: nil)
                state.channel = nil
                state.isStopped = true
            }
        }

        // Kill child process
        state.withLock { state in
            if let pid = state.childPID {
                #if canImport(Musl)
                Musl.kill(pid, SIGTERM)
                #elseif canImport(Glibc)
                Glibc.kill(pid, SIGTERM)
                #endif

                var status: Int32 = 0
                waitpid(pid, &status, 0)
                state.childPID = nil
            }
        }
    }
}
