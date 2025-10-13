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

final class FilesystemEventWorker: Sendable {
    private static let handshakeReady: UInt8 = 0xAA
    private static let handshakeFailure: UInt8 = 0xFF

    private let containerID: String
    private let containerPID: Int32
    private let eventLoop: EventLoop
    private let shouldStop: Atomic<Bool> = Atomic(false)

    // Cross-thread state (accessed from any thread)
    private struct State {
        var childPID: Int32?
        var parentSocket: Int32?
    }
    private let state: Mutex<State> = Mutex(State(childPID: nil, parentSocket: nil))

    // Event-loop confined state (only accessed on channel.eventLoop)
    private final class ELState: @unchecked Sendable {
        var channel: Channel?
        var eventIDCounter: UInt32 = 0
        var pendingEvents: [UInt32: CheckedContinuation<Void, Error>] = [:]
    }
    private let elState = ELState()

    init(containerID: String, containerPID: Int32, eventLoop: EventLoop) {
        self.containerID = containerID
        self.containerPID = containerPID
        self.eventLoop = eventLoop
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
            $0.parentSocket = parentSocket
        }

        var handshake: UInt8 = 0
        let readResult = read(parentSocket, &handshake, 1)

        if readResult != 1 {
            close(parentSocket)
            state.withLock { $0.parentSocket = nil }
            close(errorReadFD)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            state.withLock { $0.childPID = nil }
            throw ContainerizationError(.internalError, message: "Child process failed to start")
        }

        if handshake == Self.handshakeFailure {
            close(parentSocket)
            state.withLock { $0.parentSocket = nil }

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
            state.withLock { $0.parentSocket = nil }
            close(errorReadFD)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            state.withLock { $0.childPID = nil }
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
            self.elState.channel = try bootstrap.takingOwnershipOfDescriptor(inputOutput: parentSocket).wait()
        } catch {
            close(parentSocket)
            state.withLock { $0.parentSocket = nil }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            state.withLock { $0.childPID = nil }
            throw ContainerizationError(.internalError, message: "Failed to setup NIO channel: \(error)")
        }
    }

    func enqueueEvent(path: String, eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType) async throws {
        let socket = try state.withLock { state throws -> Int32 in
            guard let socket = state.parentSocket, !shouldStop.load(ordering: .relaxed) else {
                throw ContainerizationError(.invalidState, message: "FilesystemEventWorker not running")
            }
            return socket
        }

        // Use continuation to bridge between async and event loop
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Hop to event loop to access event ID counter and store continuation
            eventLoop.execute { [elState] in
                let eventID = elState.eventIDCounter
                elState.eventIDCounter += 1
                elState.pendingEvents[eventID] = continuation

                do {
                    try self.sendEventToChild(socket: socket, eventID: eventID, path: path, eventType: eventType)
                } catch {
                    // Remove continuation and resume with error on send failure
                    _ = elState.pendingEvents.removeValue(forKey: eventID)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        shouldStop.store(true, ordering: .relaxed)

        // Close channel and clean up pending events on event loop
        eventLoop.execute { [elState] in
            elState.channel?.close(promise: nil)
            elState.channel = nil

            for (_, continuation) in elState.pendingEvents {
                continuation.resume(throwing: ContainerizationError(.cancelled, message: "FilesystemEventWorker stopped"))
            }
            elState.pendingEvents.removeAll()
        }

        // Kill child process
        state.withLock { state in
            state.parentSocket = nil

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

                // ResponseHandler runs on event loop, so can access elState.pendingEvents directly
                if let continuation = worker.elState.pendingEvents.removeValue(forKey: eventID) {
                    if success == 1 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ContainerizationError(.internalError, message: "Child process failed to process filesystem event"))
                    }
                }
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            // ResponseHandler runs on event loop, so can access elState.pendingEvents directly
            for (_, continuation) in worker.elState.pendingEvents {
                continuation.resume(throwing: error)
            }
            worker.elState.pendingEvents.removeAll()
        }
    }
}
