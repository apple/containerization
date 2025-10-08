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

        let pid = fork()
        guard pid >= 0 else {
            close(parentSocket)
            close(childSocket)
            throw ContainerizationError(.internalError, message: "Failed to fork: errno \(errno)")
        }

        if pid == 0 {
            close(parentSocket)
            runChildProcess(socket: childSocket)
            exit(0)
        } else {
            close(childSocket)
            self.childPID = pid
            self.parentSocket = parentSocket

            var handshake: UInt8 = 0
            let readResult = read(parentSocket, &handshake, 1)

            if readResult != 1 {
                close(parentSocket)
                self.parentSocket = nil
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                self.childPID = nil
                throw ContainerizationError(.internalError, message: "Child process failed to start")
            }

            if handshake == Self.handshakeFailure {
                close(parentSocket)
                self.parentSocket = nil
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                self.childPID = nil
                throw ContainerizationError(.internalError, message: "Child process failed to enter container namespace")
            }

            if handshake != Self.handshakeReady {
                close(parentSocket)
                self.parentSocket = nil
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                self.childPID = nil
                throw ContainerizationError(.internalError, message: "Child process sent unexpected handshake: \(handshake)")
            }

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

    private func runChildProcess(socket: Int32) {
        do {
            try enterContainerNamespace()
        } catch {
            var failureHandshake = Self.handshakeFailure
            _ = write(socket, &failureHandshake, 1)
            close(socket)
            exit(1)
        }

        var readyHandshake = Self.handshakeReady
        guard write(socket, &readyHandshake, 1) == 1 else {
            close(socket)
            exit(1)
        }

        while true {
            do {
                guard let (eventID, path, eventType) = try readEventFromParent(socket: socket) else {
                    break
                }

                var success: UInt8 = 1
                do {
                    try generateSyntheticInotifyEvent(path: path, eventType: eventType)
                } catch {
                    success = 0
                }

                try sendResponseToParent(socket: socket, eventID: eventID, success: success)
            } catch {
                break
            }
        }

        close(socket)
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

    private func readEventFromParent(socket: Int32) throws -> (UInt32, String, Com_Apple_Containerization_Sandbox_V3_FileSystemEventType)? {
        var eventTypeValue: UInt32 = 0
        guard read(socket, &eventTypeValue, 4) == 4 else { return nil }
        eventTypeValue = UInt32(bigEndian: eventTypeValue)

        var pathLen: UInt32 = 0
        guard read(socket, &pathLen, 4) == 4 else { return nil }
        pathLen = UInt32(bigEndian: pathLen)

        let pathData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(pathLen))
        defer { pathData.deallocate() }
        guard read(socket, pathData, Int(pathLen)) == pathLen else { return nil }
        let pathBytes = Data(bytes: pathData, count: Int(pathLen))
        guard let path = String(data: pathBytes, encoding: .utf8) else { return nil }

        var eventID: UInt32 = 0
        guard read(socket, &eventID, 4) == 4 else { return nil }
        eventID = UInt32(bigEndian: eventID)

        guard let eventType = Com_Apple_Containerization_Sandbox_V3_FileSystemEventType(rawValue: Int(eventTypeValue)) else {
            return nil
        }

        return (eventID, path, eventType)
    }

    private func sendResponseToParent(socket: Int32, eventID: UInt32, success: UInt8) throws {
        var buffer = Data()
        buffer.append(contentsOf: withUnsafeBytes(of: eventID.bigEndian) { Data($0) })
        buffer.append(success)

        try buffer.withUnsafeBytes { bytes in
            let written = write(socket, bytes.bindMemory(to: UInt8.self).baseAddress, buffer.count)
            guard written == buffer.count else {
                throw ContainerizationError(.internalError, message: "Failed to write response to parent")
            }
        }
    }

    private func enterContainerNamespace() throws {
        let nsPath = "/proc/\(containerPID)/ns/mnt"
        let vmNsPath = "/proc/self/ns/mnt"

        guard FileManager.default.fileExists(atPath: nsPath) else {
            throw ContainerizationError(.internalError, message: "Namespace file does not exist: \(nsPath)")
        }

        let containerNsStatPtr = UnsafeMutablePointer<stat>.allocate(capacity: 1)
        let vmNsStatPtr = UnsafeMutablePointer<stat>.allocate(capacity: 1)
        defer {
            containerNsStatPtr.deallocate()
            vmNsStatPtr.deallocate()
        }

        let containerStatResult = stat(nsPath, containerNsStatPtr)
        let vmStatResult = stat(vmNsPath, vmNsStatPtr)

        if containerStatResult == 0 && vmStatResult == 0 {
            let containerInode = containerNsStatPtr.pointee.st_ino
            let vmInode = vmNsStatPtr.pointee.st_ino

            if containerInode == vmInode {
                return
            }
        }

        let fd = open(nsPath, O_RDONLY)
        guard fd >= 0 else {
            throw ContainerizationError(.internalError, message: "Failed to open namespace file: \(nsPath), errno \(errno)")
        }
        defer {
            _ = close(fd)
        }

        let setnsResult = setns(fd, CLONE_NEWNS)
        guard setnsResult == 0 else {
            throw ContainerizationError(.internalError, message: "Failed to setns to mount namespace: errno \(errno)")
        }
    }

    private func generateSyntheticInotifyEvent(
        path: String,
        eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType
    ) throws {
        if eventType == .delete && !FileManager.default.fileExists(atPath: path) {
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw ContainerizationError(.internalError, message: "Failed to get file permissions for path: \(path)")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: path
        )
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
