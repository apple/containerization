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
        var isStarted: Bool = false
        var isStopped: Bool = false
        var channel: Channel?
    }
    private let state: Mutex<State> = Mutex(State(isStarted: false, isStopped: false))

    init(containerID: String, containerPID: Int32, eventLoop: EventLoop, log: Logger) {
        self.containerID = containerID
        self.containerPID = containerPID
        self.eventLoop = eventLoop
        self.log = log
    }

    func start() throws {
        guard !state.withLock({ $0.isStarted }) else {
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

        let containerID = self.containerID
        let containerPID = self.containerPID
        let log = self.log

        let thread = Thread { [weak self] in
            defer {
                close(childSocket)
            }

            self?.runWorkerThread(
                socket: childSocket,
                errorPipe: errorWriteFD,
                containerID: containerID,
                containerPID: containerPID,
                log: log
            )
        }
        thread.name = "fsnotify-\(containerID)"
        thread.start()

        state.withLock { $0.isStarted = true }

        var handshake: UInt8 = 0
        let readResult = read(parentSocket, &handshake, 1)

        if readResult != 1 {
            close(parentSocket)
            close(errorReadFD)
            state.withLock { $0.isStarted = false }
            throw ContainerizationError(.internalError, message: "Worker thread failed to send handshake")
        }

        if handshake == Self.handshakeFailure {
            close(parentSocket)

            // Read error message from thread
            var errorBuffer = [UInt8](repeating: 0, count: 1024)
            let bytesRead = read(errorReadFD, &errorBuffer, errorBuffer.count)
            close(errorReadFD)

            state.withLock { $0.isStarted = false }

            let errorMsg =
                bytesRead > 0
                ? (String(bytes: errorBuffer.prefix(bytesRead), encoding: .utf8) ?? "unknown error")
                : "no error message"
            throw ContainerizationError(.internalError, message: "Worker thread failed: \(errorMsg)")
        }

        if handshake != Self.handshakeReady {
            close(parentSocket)
            close(errorReadFD)
            state.withLock { $0.isStarted = false }
            throw ContainerizationError(.internalError, message: "Worker thread sent unexpected handshake: \(handshake)")
        }

        // Success - close error pipe read end
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
            state.withLock { $0.isStarted = false }
            throw ContainerizationError(.internalError, message: "Failed to setup NIO channel: \(error)")
        }
    }

    private func runWorkerThread(
        socket: Int32,
        errorPipe: Int32,
        containerID: String,
        containerPID: Int32,
        log: Logger
    ) {
        // Helper to send error and handshake failure
        func sendError(_ message: String) {
            _ = message.utf8CString.withUnsafeBufferPointer { buffer in
                write(errorPipe, buffer.baseAddress, buffer.count - 1)
            }
            close(errorPipe)
            var failureHandshake = Self.handshakeFailure
            _ = write(socket, &failureHandshake, 1)
        }

        do {
            try enterContainerNamespace(containerPID: containerPID, log: log)
        } catch {
            sendError("Failed to enter namespace: \(error)")
            return
        }

        close(errorPipe)
        var readyHandshake = Self.handshakeReady
        guard write(socket, &readyHandshake, 1) == 1 else {
            return
        }

        while true {
            do {
                guard let (path, eventType) = try readEventFromParent(socket: socket) else {
                    break
                }

                do {
                    try generateSyntheticInotifyEvent(path: path, eventType: eventType)
                } catch {
                    let errorMsg = "Failed to generate inotify event: path=\(path), type=\(eventType), error=\(error)"
                    fputs(errorMsg + "\n", stderr)
                    fflush(stderr)
                }
            } catch {
                fputs("Protocol error reading from parent: \(error)\n", stderr)
                fflush(stderr)
                break
            }
        }
    }

    private func enterContainerNamespace(containerPID: Int32, log: Logger) throws {
        let nsPath = "/proc/\(containerPID)/ns/mnt"
        let vmNsPath = "/proc/self/ns/mnt"

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
            close(fd)
        }

        #if canImport(Musl)
        let unshareResult = Musl.unshare(CLONE_FS)
        #elseif canImport(Glibc)
        let unshareResult = Glibc.unshare(CLONE_FS)
        #endif
        guard unshareResult == 0 else {
            throw ContainerizationError(.internalError, message: "Failed to unshare filesystem structure: errno \(errno)")
        }

        #if canImport(Musl)
        let setnsResult = Musl.setns(fd, CLONE_NEWNS)
        #elseif canImport(Glibc)
        let setnsResult = Glibc.setns(fd, CLONE_NEWNS)
        #endif
        guard setnsResult == 0 else {
            throw ContainerizationError(.internalError, message: "Failed to setns to mount namespace: errno \(errno)")
        }
    }

    private func readEventFromParent(socket: Int32) throws -> (String, FileSystemEventType)? {
        var eventTypeValue: UInt32 = 0
        guard read(socket, &eventTypeValue, 4) == 4 else {
            return nil
        }
        eventTypeValue = UInt32(bigEndian: eventTypeValue)

        var pathLen: UInt32 = 0
        guard read(socket, &pathLen, 4) == 4 else {
            throw ContainerizationError(.internalError, message: "Failed to read path length from parent")
        }
        pathLen = UInt32(bigEndian: pathLen)

        let pathData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(pathLen))
        defer { pathData.deallocate() }
        guard read(socket, pathData, Int(pathLen)) == pathLen else {
            throw ContainerizationError(.internalError, message: "Failed to read path from parent")
        }
        let pathBytes = Data(bytes: pathData, count: Int(pathLen))
        guard let path = String(data: pathBytes, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "Failed to decode path as UTF-8")
        }

        guard let eventType = FileSystemEventType(rawValue: Int(eventTypeValue)) else {
            throw ContainerizationError(.internalError, message: "Invalid event type: \(eventTypeValue)")
        }

        return (path, eventType)
    }

    private func generateSyntheticInotifyEvent(
        path: String,
        eventType: FileSystemEventType
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
        state.withLock { state in
            state.isStopped = true
            state.isStarted = false
        }

        eventLoop.execute {
            self.state.withLock { state in
                state.channel?.close(promise: nil)
                state.channel = nil
            }
        }
    }
}
