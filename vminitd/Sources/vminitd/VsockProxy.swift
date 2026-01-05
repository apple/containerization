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

import ContainerizationIO
import ContainerizationOS
import Foundation
import Logging

actor VsockProxy {
    enum Action {
        case listen
        case dial
    }

    private enum SocketType {
        case unix
        case vsock
    }

    public let id: String
    private let path: URL
    private let action: Action
    private let port: UInt32
    private let udsPerms: UInt32?
    private let log: Logger?

    private var listener: Socket?
    private var task: Task<(), Never>?

    init(
        id: String,
        action: Action,
        port: UInt32,
        path: URL,
        udsPerms: UInt32?,
        log: Logger? = nil
    ) {
        self.id = id
        self.action = action
        self.port = port
        self.path = path
        self.udsPerms = udsPerms
        self.log = log
    }
}

extension VsockProxy {
    func close() throws {
        guard let listener else {
            return
        }

        log?.info(
            "stopping proxy",
            metadata: [
                "vport": "\(port)",
                "uds": "\(path)",
                "action": "\(action)",
            ])
        try listener.close()
        let fm = FileManager.default
        if fm.fileExists(atPath: self.path.path) {
            try FileManager.default.removeItem(at: self.path)
        }
        task?.cancel()
        self.listener = nil
    }

    func start() throws {
        guard listener == nil else {
            return
        }

        log?.info(
            "starting proxy",
            metadata: [
                "vport": "\(port)",
                "uds": "\(path)",
                "action": "\(action)",
            ])
        switch self.action {
        case .dial:
            try dialHost()
        case .listen:
            try dialGuest()
        }
    }

    private func dialHost() throws {
        let fm = FileManager.default

        let parentDir = self.path.deletingLastPathComponent()
        try fm.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true
        )

        let type = try UnixType(
            path: self.path.path,
            perms: self.udsPerms,
            unlinkExisting: true
        )
        let oldMask = umask(0)
        defer { umask(oldMask) }
        let uds = try Socket(type: type)
        try uds.listen()
        listener = uds

        try self.acceptLoop(socketType: .unix)
    }

    private func dialGuest() throws {
        let type = VsockType(
            port: self.port,
            cid: VsockType.anyCID
        )
        let vsock = try Socket(type: type)
        try vsock.listen()
        listener = vsock

        try self.acceptLoop(socketType: .vsock)
    }

    private func acceptLoop(socketType: SocketType) throws {
        guard let listener else {
            return
        }

        let stream = try listener.acceptStream()
        let task = Task {
            do {
                for try await conn in stream {
                    Task {
                        log?.info(
                            "accepting connection",
                            metadata: [
                                "vport": "\(port)",
                                "uds": "\(path)",
                                "action": "\(action)",
                                "socketType": "\(socketType)",
                            ])
                        do {
                            try await handleConn(
                                conn: conn,
                                connType: socketType
                            )
                        } catch {
                            self.log?.error("failed to handle connection: \(error)")
                        }
                    }
                }
            } catch {
                self.log?.error("failed to accept connection: \(error)")
            }
        }
        self.task = task
    }

    private func handleConn(
        conn: ContainerizationOS.Socket,
        connType: SocketType
    ) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            do {
                // `relayTo` isn't used concurrently.
                nonisolated(unsafe) var relayTo: ContainerizationOS.Socket

                switch connType {
                case .unix:
                    let type = VsockType(
                        port: self.port,
                        cid: VsockType.hostCID
                    )
                    relayTo = try Socket(
                        type: type,
                        closeOnDeinit: false
                    )
                case .vsock:
                    let type = try UnixType(path: self.path.path)
                    relayTo = try Socket(
                        type: type,
                        closeOnDeinit: false
                    )
                }

                try relayTo.connect()

                // `clientFile` isn't used concurrently.
                nonisolated(unsafe) var clientFile = OSFile.SpliceFile(fd: conn.fileDescriptor)
                nonisolated(unsafe) var eofFromClient = false
                // `serverFile` isn't used concurrently.
                nonisolated(unsafe) var serverFile = OSFile.SpliceFile(fd: relayTo.fileDescriptor)
                nonisolated(unsafe) var eofFromServer = false

                // clean up when any of these conditions apply:
                //   - the client has completely hung up or errored
                //   - the server has completely hung up or errored
                //   - both the client and server have half closed via:
                //     - read hangup on epoll
                //     - EOF on splice
                let cleanup = { @Sendable [log, port, path, action] in
                    log?.info(
                        "cleaning up",
                        metadata: [
                            "vport": "\(port)",
                            "uds": "\(path)",
                            "action": "\(action)",
                            "eofFromClient": "\(eofFromClient)",
                            "eofFromServer": "\(eofFromServer)",
                            "clientFd": "\(clientFile.fileDescriptor)",
                            "serverFd": "\(serverFile.fileDescriptor)",
                        ]
                    )

                    do {
                        try ProcessSupervisor.default.poller.delete(clientFile.fileDescriptor)
                        try ProcessSupervisor.default.poller.delete(serverFile.fileDescriptor)
                        try conn.close()
                        try relayTo.close()
                    } catch {
                        self.log?.error("Failed to clean up vsock proxy: \(error)")
                    }
                    c.resume()
                }

                try! ProcessSupervisor.default.poller.add(clientFile.fileDescriptor, mask: EPOLLIN | EPOLLOUT) { mask in
                    if mask.readyToRead && !eofFromClient {
                        let (fromEof, toEof) = Self.transferData(
                            fromFile: &clientFile,
                            toFile: &serverFile,
                            description: "readyToRead:toServer",
                            log: self.log
                        )
                        eofFromClient = eofFromClient || fromEof
                        eofFromServer = eofFromServer || toEof
                    }

                    if mask.readyToWrite && !eofFromServer {
                        let (fromEof, toEof) = Self.transferData(
                            fromFile: &serverFile,
                            toFile: &clientFile,
                            description: "readyToWrite:toClient",
                            log: self.log
                        )
                        eofFromClient = eofFromClient || toEof
                        eofFromServer = eofFromServer || fromEof
                    }

                    if mask.isHangup {
                        eofFromClient = true
                        eofFromServer = true
                    } else if mask.isRhangup && !eofFromClient {
                        // half close, shut down client to server transfer
                        // we should see no more EPOLLIN events on the client fd
                        // and no more EPOLLOUT events on the server fd
                        eofFromClient = true
                        if shutdown(serverFile.fileDescriptor, SHUT_WR) != 0 {
                            self.log?.warning(
                                "failed to shut down client reads",
                                metadata: [
                                    "vport": "\(self.port)",
                                    "uds": "\(self.path)",
                                    "errno": "\(errno)",
                                    "eofFromClient": "\(eofFromClient)",
                                    "eofFromServer": "\(eofFromServer)",
                                    "clientFd": "\(clientFile.fileDescriptor)",
                                    "serverFd": "\(serverFile.fileDescriptor)",
                                ]
                            )
                        }
                    }

                    if eofFromClient && eofFromServer {
                        return cleanup()
                    }
                }

                try! ProcessSupervisor.default.poller.add(serverFile.fileDescriptor, mask: EPOLLIN | EPOLLOUT) { mask in
                    if mask.readyToRead && !eofFromServer {
                        let (fromEof, toEof) = Self.transferData(
                            fromFile: &serverFile,
                            toFile: &clientFile,
                            description: "readyToRead:toClient",
                            log: self.log
                        )
                        eofFromClient = eofFromClient || toEof
                        eofFromServer = eofFromServer || fromEof
                    }

                    if mask.readyToWrite && !eofFromClient {
                        let (fromEof, toEof) = Self.transferData(
                            fromFile: &clientFile,
                            toFile: &serverFile,
                            description: "readyToWrite:toServer",
                            log: self.log
                        )
                        eofFromClient = eofFromClient || fromEof
                        eofFromServer = eofFromServer || toEof
                    }

                    if mask.isHangup {
                        eofFromClient = true
                        eofFromServer = true
                    } else if mask.isRhangup && !eofFromServer {
                        // half close, shut down server to client transfer
                        // we should see no more EPOLLIN events on the server fd
                        // and no more EPOLLOUT events on the client fd
                        eofFromServer = true
                        if shutdown(clientFile.fileDescriptor, SHUT_WR) != 0 {
                            self.log?.warning(
                                "failed to shut down server reads",
                                metadata: [
                                    "vport": "\(self.port)",
                                    "uds": "\(self.path)",
                                    "errno": "\(errno)",
                                    "eofFromClient": "\(eofFromClient)",
                                    "eofFromServer": "\(eofFromServer)",
                                    "clientFd": "\(clientFile.fileDescriptor)",
                                    "serverFd": "\(serverFile.fileDescriptor)",
                                ]
                            )
                        }
                    }

                    if eofFromClient && eofFromServer {
                        return cleanup()
                    }
                }
            } catch {
                c.resume(throwing: error)
            }
        }
    }

    private static func transferData(
        fromFile: inout OSFile.SpliceFile,
        toFile: inout OSFile.SpliceFile,
        description: String,
        log: Logger?
    ) -> (Bool, Bool) {
        do {
            let (readBytes, writeBytes, action) = try OSFile.splice(from: &fromFile, to: &toFile)
            log?.trace(
                "transferred data",
                metadata: [
                    "description": "\(description)",
                    "action": "\(action)",
                    "readBytes": "\(readBytes)",
                    "writeBytes": "\(writeBytes)",
                    "fromFd": "\(fromFile.fileDescriptor)",
                    "toFd": "\(toFile.fileDescriptor)",
                ]
            )
            if action == .eof {
                // half close, shut down client to server transfer
                // we should see no more EPOLLIN events on the client fd
                // and no more EPOLLOUT events on the server fd
                if shutdown(toFile.fileDescriptor, SHUT_WR) != 0 {
                    log?.warning(
                        "failed to shut down reads",
                        metadata: [
                            "description": "\(description)",
                            "errno": "\(errno)",
                            "action": "\(action)",
                            "readBytes": "\(readBytes)",
                            "writeBytes": "\(writeBytes)",
                            "fromFd": "\(fromFile.fileDescriptor)",
                            "toFd": "\(toFile.fileDescriptor)",
                        ]
                    )
                }
                return (true, false)
            } else if action == .brokenPipe {
                return (true, true)
            }
            return (false, false)
        } catch {
            return (true, true)
        }
    }
}
