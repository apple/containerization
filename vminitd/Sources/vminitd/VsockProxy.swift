//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
import SendableProperty

final class VsockProxy: Sendable {
    enum Action {
        case listen
        case dial
    }

    private enum SocketType {
        case unix
        case vsock
    }

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

    public let id: String
    private let path: URL
    private let action: Action
    private let port: UInt32
    private let udsPerms: UInt32?
    private let log: Logger?

    @SendableProperty
    private var state = State()

    private struct State {
        var listener: Socket?
        var task: Task<(), Never>?
    }
}

extension VsockProxy {
    func close() throws {
        guard let listener = state.listener else {
            return
        }

        try listener.close()
        let fm = FileManager.default
        if fm.fileExists(atPath: self.path.path) {
            try FileManager.default.removeItem(at: self.path)
        }
        state.task?.cancel()
    }

    func start() throws {
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
        let uds = try Socket(type: type)
        try uds.listen()
        state.listener = uds

        try self.acceptLoop(socketType: .unix)
    }

    private func dialGuest() throws {
        let type = VsockType(
            port: self.port,
            cid: VsockType.anyCID
        )
        let vsock = try Socket(type: type)
        try vsock.listen()
        state.listener = vsock

        try self.acceptLoop(socketType: .vsock)
    }

    private func acceptLoop(socketType: SocketType) throws {
        guard let listener = state.listener else {
            return
        }

        let stream = try listener.acceptStream()
        state.task = Task {
            do {
                for try await conn in stream {
                    Task {
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
                // `serverFile` isn't used concurrently.
                nonisolated(unsafe) var serverFile = OSFile.SpliceFile(fd: relayTo.fileDescriptor)

                let cleanup = { @Sendable in
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
                    if mask.readyToRead {
                        do {
                            let (_, _, action) = try OSFile.splice(from: &clientFile, to: &serverFile)
                            if action == .eof || action == .brokenPipe {
                                return cleanup()
                            }
                        } catch {
                            return cleanup()
                        }
                    }

                    if mask.readyToWrite {
                        do {
                            let (_, _, action) = try OSFile.splice(from: &serverFile, to: &clientFile)
                            if action == .eof || action == .brokenPipe {
                                return cleanup()
                            }
                        } catch {
                            return cleanup()
                        }
                    }

                    if mask.isHangup {
                        return cleanup()
                    }
                }

                try! ProcessSupervisor.default.poller.add(serverFile.fileDescriptor, mask: EPOLLIN | EPOLLOUT) { mask in
                    if mask.readyToRead {
                        do {
                            let (_, _, action) = try OSFile.splice(from: &serverFile, to: &clientFile)
                            if action == .eof || action == .brokenPipe {
                                return cleanup()
                            }
                        } catch {
                            return cleanup()
                        }
                    }

                    if mask.readyToWrite {
                        do {
                            let (_, _, action) = try OSFile.splice(from: &clientFile, to: &serverFile)
                            if action == .eof || action == .brokenPipe {
                                return cleanup()
                            }
                        } catch {
                            return cleanup()
                        }
                    }

                    if mask.isHangup {
                        return cleanup()
                    }
                }
            } catch {
                c.resume(throwing: error)
            }
        }
    }
}
