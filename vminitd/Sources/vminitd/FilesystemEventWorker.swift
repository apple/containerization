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
import NIOCore
import NIOPosix
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

final class FilesystemEventWorker: @unchecked Sendable {
    private static let handshakeReady: UInt8 = 0xAA
    private static let handshakeFailure: UInt8 = 0xFF

    private let containerID: String
    private let containerPID: Int32
    private var childPID: Int32?
    private var parentSocket: Int32?
    private var channel: Channel?
    private let eventLoop: EventLoop
    private var eventIDCounter: UInt32 = 0
    private let pendingEvents: Mutex<[UInt32: CheckedContinuation<Void, Error>]> = Mutex([:])
    private let shouldStop: Atomic<Bool> = Atomic(false)

    init(containerID: String, containerPID: Int32, eventLoop: EventLoop) {
        self.containerID = containerID
        self.containerPID = containerPID
        self.eventLoop = eventLoop
    }

    func start() throws {
        guard childPID == nil else {
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
        self.childPID = pid
        self.parentSocket = parentSocket

        var handshake: UInt8 = 0
        let readResult = read(parentSocket, &handshake, 1)

        if readResult != 1 {
            close(parentSocket)
            self.parentSocket = nil
            close(errorReadFD)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self.childPID = nil
            throw ContainerizationError(.internalError, message: "Child process failed to start")
        }

        if handshake == Self.handshakeFailure {
            close(parentSocket)
            self.parentSocket = nil

            // Read error message from child
            var errorBuffer = [UInt8](repeating: 0, count: 1024)
            let bytesRead = read(errorReadFD, &errorBuffer, errorBuffer.count)
            close(errorReadFD)

            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self.childPID = nil

            let errorMsg =
                bytesRead > 0
                ? (String(bytes: errorBuffer.prefix(bytesRead), encoding: .utf8) ?? "unknown error")
                : "no error message"
            throw ContainerizationError(.internalError, message: "Child process failed: \(errorMsg)")
        }

        if handshake != Self.handshakeReady {
            close(parentSocket)
            self.parentSocket = nil
            close(errorReadFD)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self.childPID = nil
            throw ContainerizationError(.internalError, message: "Child process sent unexpected handshake: \(handshake)")
        }

        // Success - close error pipe
        close(errorReadFD)

        do {
            let bootstrap = NIOPipeBootstrap(group: eventLoop)
                .channelInitializer { channel in
                    let handler = ResponseHandler(worker: self)
                    return channel.pipeline.addHandler(handler)
                }
            self.channel = try bootstrap.takingOwnershipOfDescriptor(inputOutput: parentSocket).wait()
        } catch {
            close(parentSocket)
            self.parentSocket = nil
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self.childPID = nil
            throw ContainerizationError(.internalError, message: "Failed to setup NIO channel: \(error)")
        }
    }

    func enqueueEvent(path: String, eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType) async throws {
        guard let socket = parentSocket, !shouldStop.load(ordering: .relaxed) else {
            throw ContainerizationError(.invalidState, message: "FilesystemEventWorker not running")
        }

        let eventID = eventIDCounter
        eventIDCounter += 1

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingEvents.withLock { events in
                events[eventID] = continuation
            }

            do {
                try sendEventToChild(socket: socket, eventID: eventID, path: path, eventType: eventType)
            } catch {
                _ = pendingEvents.withLock { events in
                    events.removeValue(forKey: eventID)
                }
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        shouldStop.store(true, ordering: .relaxed)

        if let channel = self.channel {
            try? channel.close().wait()
            self.channel = nil
        }

        self.parentSocket = nil

        if let pid = childPID {
            #if canImport(Musl)
            Musl.kill(pid, SIGTERM)
            #elseif canImport(Glibc)
            Glibc.kill(pid, SIGTERM)
            #endif

            var status: Int32 = 0
            waitpid(pid, &status, 0)
            childPID = nil
        }

        pendingEvents.withLock { events in
            for (_, continuation) in events {
                continuation.resume(throwing: ContainerizationError(.cancelled, message: "FilesystemEventWorker stopped"))
            }
            events.removeAll()
        }
    }

    private func sendEventToChild(socket: Int32, eventID: UInt32, path: String, eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType) throws {
        let pathData = path.data(using: .utf8) ?? Data()
        let pathLen = UInt32(pathData.count)
        let eventTypeValue = UInt32(eventType.rawValue)

        var buffer = Data()
        buffer.append(contentsOf: withUnsafeBytes(of: eventTypeValue.bigEndian) { Data($0) })
        buffer.append(contentsOf: withUnsafeBytes(of: pathLen.bigEndian) { Data($0) })
        buffer.append(pathData)
        buffer.append(contentsOf: withUnsafeBytes(of: eventID.bigEndian) { Data($0) })

        try buffer.withUnsafeBytes { bytes in
            let written = write(socket, bytes.bindMemory(to: UInt8.self).baseAddress, buffer.count)
            guard written == buffer.count else {
                throw ContainerizationError(.internalError, message: "Failed to write event to child: written \(written), expected \(buffer.count)")
            }
        }
    }

    private final class ResponseHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private var buffer = ByteBuffer()
        private unowned let worker: FilesystemEventWorker

        init(worker: FilesystemEventWorker) {
            self.worker = worker
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var inBuffer = unwrapInboundIn(data)
            buffer.writeBuffer(&inBuffer)

            while buffer.readableBytes >= 5 {
                guard let eventID = buffer.readInteger(endianness: .big, as: UInt32.self),
                    let success = buffer.readInteger(as: UInt8.self)
                else {
                    break
                }

                worker.pendingEvents.withLock { events in
                    if let continuation = events.removeValue(forKey: eventID) {
                        if success == 1 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: ContainerizationError(.internalError, message: "Child process failed to process filesystem event"))
                        }
                    }
                }
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            worker.pendingEvents.withLock { events in
                for (_, continuation) in events {
                    continuation.resume(throwing: error)
                }
                events.removeAll()
            }
        }
    }
}
