//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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

#if os(Linux)

import ContainerizationOS
import Foundation
import Logging
import NIOPosix
import Synchronization

actor VsockProxy {
    enum Action {
        case listen
        case dial
    }

    private enum SocketType {
        case unix
        case vsock
    }

    let id: String

    private let path: URL
    private let action: Action
    private let port: UInt32
    private let udsPerms: UInt32?
    private let blockingPool: NIOThreadPool
    private let log: Logger?

    private var listener: Socket?
    private var closing: Task<Void, any Error>?
    private var task: Task<(), Never>?
    private var connectionTasks: [UUID: Task<(), Never>] = [:]

    init(
        id: String,
        action: Action,
        port: UInt32,
        path: URL,
        udsPerms: UInt32?,
        blockingPool: NIOThreadPool,
        log: Logger? = nil
    ) {
        self.id = id
        self.action = action
        self.port = port
        self.path = path
        self.udsPerms = udsPerms
        self.blockingPool = blockingPool
        self.log = log
    }
}

extension VsockProxy {
    func start() async throws {
        _ = await closing?.result
        guard listener == nil else {
            return
        }

        log?.debug(
            "starting proxy",
            metadata: [
                "vport": "\(port)",
                "uds": "\(path)",
                "action": "\(action)",
            ])

        switch action {
        case .dial:
            try dialHost()
        case .listen:
            try dialGuest()
        }
    }

    func close() async throws {
        guard let listener else {
            try await closing?.value
            return
        }

        log?.debug(
            "stopping proxy",
            metadata: [
                "vport": "\(port)",
                "uds": "\(path)",
                "action": "\(action)",
            ])

        for (_, t) in connectionTasks { t.cancel() }
        connectionTasks.removeAll()
        task?.cancel()
        self.task = nil
        self.listener = nil

        // Unlink before suspending so a restart during the wait keeps its new socket file.
        var removeError: (any Error)?
        if action == .dial, FileManager.default.fileExists(atPath: path.path) {
            do { try FileManager.default.removeItem(at: path) } catch { removeError = error }
        }

        // A pending accept holds the listener open; returning after release lets the
        // port and socket be reused as soon as the stop request completes.
        let closing = Task { [removeError] in
            try await listener.closeAndWait()
            if let removeError { throw removeError }
        }
        self.closing = closing
        defer { if self.closing == closing { self.closing = nil } }
        try await closing.value
    }

    private func dialHost() throws {
        let fm = FileManager.default

        let parentDir = path.deletingLastPathComponent()
        try fm.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true
        )

        let type = try UnixType(
            path: path.path,
            perms: udsPerms,
            unlinkExisting: true
        )
        let oldMask = umask(0)
        defer { umask(oldMask) }
        let uds = try Socket(type: type)
        try uds.listen()
        listener = uds

        try acceptLoop(socketType: .unix)
    }

    private func dialGuest() throws {
        let type = VsockType(
            port: port,
            cid: VsockType.anyCID
        )
        let vsock = try Socket(type: type)
        try vsock.listen()
        listener = vsock

        try acceptLoop(socketType: .vsock)
    }

    private func acceptLoop(socketType: SocketType) throws {
        guard let listener else {
            return
        }

        let stream = try listener.acceptStream()
        let task = Task {
            do {
                for try await conn in stream {
                    // An accept can race shutdown; child tasks do not inherit cancellation.
                    guard !Task.isCancelled else {
                        try? conn.close()
                        break
                    }
                    let connID = UUID()
                    let connTask = Task {
                        defer { self.connectionTasks[connID] = nil }
                        log?.debug(
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
                    // Safe: actor serialization ensures this runs before connTask can execute its defer.
                    connectionTasks[connID] = connTask
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
        let relayTo: Socket
        switch connType {
        case .unix:
            relayTo = try Socket(type: VsockType(port: port, cid: VsockType.hostCID))
        case .vsock:
            relayTo = try Socket(type: UnixType(path: path.path))
        }
        // Bounds how long a stalled connect holds a thread of the shared connect pool.
        try relayTo.setTimeout(option: .send, seconds: 10)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                blockingPool.submit { state in
                    switch state {
                    case .active:
                        continuation.resume(with: Result { try relayTo.connect() })
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
            try Task.checkCancellation()
            try await Self.relay(client: conn.takeDescriptor(), server: relayTo.takeDescriptor(), log: log)
        } onCancel: {
            try? conn.close()
            try? relayTo.close()
        }
    }

    static func relay(client: consuming DescriptorTransfer, server: consuming DescriptorTransfer, log: Logger? = nil) async throws {
        let session = try Connection(client: consume client, server: consume server, log: log)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { session.start($0) }
        } onCancel: {
            session.cancel()
        }
    }

    /// Both registrations share one terminal decision; copied callbacks retain both descriptor uses.
    private final class Connection: Sendable {
        private struct State {
            var clientFile: OSFile.SpliceFile
            var serverFile: OSFile.SpliceFile
            var clientUse: OwnedDescriptor.Use?
            var serverUse: OwnedDescriptor.Use?
            var eofFromClient = false
            var eofFromServer = false
            var registered: [Int32] = []
            var continuation: CheckedContinuation<Void, Error>?
            var finished = false
            var failure: (any Error)?
        }

        private let client: OwnedDescriptor
        private let server: OwnedDescriptor
        private let state: Mutex<State>
        private let log: Logger?
        private let cancelled = Atomic(false)

        init(client: consuming DescriptorTransfer, server: consuming DescriptorTransfer, log: Logger?) throws {
            let clientOwner = client.takeOwner()
            let serverOwner = server.takeOwner()
            do {
                let clientUse = try clientOwner.acquire()
                let serverUse = try serverOwner.acquire()
                self.client = clientOwner
                self.server = serverOwner
                self.log = log
                self.state = Mutex(
                    State(
                        clientFile: OSFile.SpliceFile(fd: clientUse.fileDescriptor),
                        serverFile: OSFile.SpliceFile(fd: serverUse.fileDescriptor),
                        clientUse: clientUse,
                        serverUse: serverUse
                    ))
            } catch {
                try? clientOwner.close()
                try? serverOwner.close()
                throw error
            }
        }

        func start(_ continuation: CheckedContinuation<Void, Error>) {
            do {
                let previous: Result<Void, Error>? = try self.state.withLock { state in
                    if state.finished {
                        return state.failure.map { .failure($0) } ?? .success(())
                    }
                    state.continuation = continuation
                    guard let clientUse = state.clientUse, let serverUse = state.serverUse else {
                        throw CancellationError()
                    }
                    // Callbacks can read or close either socket, so finish both registrations first.
                    try ProcessSupervisor.default.registerFd(clientUse.fileDescriptor) { [self, clientUse, serverUse] mask in
                        defer { withExtendedLifetime((clientUse, serverUse)) {} }
                        self.handle(mask, fromClient: true)
                    }
                    state.registered.append(clientUse.fileDescriptor)
                    try ProcessSupervisor.default.registerFd(serverUse.fileDescriptor) { [self, clientUse, serverUse] mask in
                        defer { withExtendedLifetime((clientUse, serverUse)) {} }
                        self.handle(mask, fromClient: false)
                    }
                    state.registered.append(serverUse.fileDescriptor)
                    return nil
                }
                if let previous { continuation.resume(with: previous) }
            } catch {
                self.finish(throwing: error)
            }
        }

        private func handle(_ mask: Epoll.Mask, fromClient: Bool) {
            let done = self.state.withLock { state in
                guard !state.finished, state.registered.count == 2 else { return false }
                // A full hangup stops writes to that endpoint, but its queued reads must drain.
                if fromClient {
                    if mask.isHangup { state.eofFromServer = true }
                    if (mask.readyToRead || mask.isHangup || mask.isRemoteHangup) && !state.eofFromClient {
                        let (fromEOF, toEOF) = VsockProxy.transferData(
                            fromFile: &state.clientFile, toFile: &state.serverFile, description: "readyToRead:toServer", log: self.log,
                            shouldStop: { self.cancelled.load(ordering: .relaxed) })
                        state.eofFromClient = state.eofFromClient || fromEOF
                        state.eofFromServer = state.eofFromServer || toEOF
                    }
                    if mask.readyToWrite && !state.eofFromServer {
                        let (fromEOF, toEOF) = VsockProxy.transferData(
                            fromFile: &state.serverFile, toFile: &state.clientFile, description: "readyToWrite:toClient", log: self.log,
                            shouldStop: { self.cancelled.load(ordering: .relaxed) })
                        state.eofFromClient = state.eofFromClient || toEOF
                        state.eofFromServer = state.eofFromServer || fromEOF
                    }
                } else {
                    if mask.isHangup { state.eofFromClient = true }
                    if (mask.readyToRead || mask.isHangup || mask.isRemoteHangup) && !state.eofFromServer {
                        let (fromEOF, toEOF) = VsockProxy.transferData(
                            fromFile: &state.serverFile, toFile: &state.clientFile, description: "readyToRead:toClient", log: self.log,
                            shouldStop: { self.cancelled.load(ordering: .relaxed) })
                        state.eofFromClient = state.eofFromClient || toEOF
                        state.eofFromServer = state.eofFromServer || fromEOF
                    }
                    if mask.readyToWrite && !state.eofFromClient {
                        let (fromEOF, toEOF) = VsockProxy.transferData(
                            fromFile: &state.clientFile, toFile: &state.serverFile, description: "readyToWrite:toServer", log: self.log,
                            shouldStop: { self.cancelled.load(ordering: .relaxed) })
                        state.eofFromClient = state.eofFromClient || fromEOF
                        state.eofFromServer = state.eofFromServer || toEOF
                    }
                }
                return state.eofFromClient && state.eofFromServer
            }
            if done { self.finish() }
        }

        func cancel() {
            // Interrupt a busy splice loop before waiting for its mutex.
            self.cancelled.store(true, ordering: .relaxed)
            self.finish(throwing: CancellationError())
        }

        func finish(throwing requestedFailure: (any Error)? = nil) {
            let cleanup = self.state.withLock { state -> ([Int32], CheckedContinuation<Void, Error>?, (any Error)?)? in
                guard !state.finished else { return nil }
                state.finished = true
                state.failure = self.cancelled.load(ordering: .relaxed) ? CancellationError() : requestedFailure
                let result = (state.registered, state.continuation, state.failure)
                state.registered.removeAll()
                state.continuation = nil
                state.clientUse = nil
                state.serverUse = nil
                return result
            }
            guard let (registrations, continuation, failure) = cleanup else { return }
            for fd in registrations {
                do { try ProcessSupervisor.default.unregisterFd(fd) } catch { self.log?.error("failed to unregister vsock proxy descriptor \(fd): \(error)") }
            }
            do { try self.client.close() } catch { self.log?.error("failed to close vsock proxy client: \(error)") }
            do { try self.server.close() } catch { self.log?.error("failed to close vsock proxy server: \(error)") }
            if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
        }

        deinit {
            try? self.client.close()
            try? self.server.close()
        }
    }

    private static func transferData(
        fromFile: inout OSFile.SpliceFile,
        toFile: inout OSFile.SpliceFile,
        description: String,
        log: Logger?,
        shouldStop: @Sendable () -> Bool
    ) -> (Bool, Bool) {
        do {
            let (readBytes, writeBytes, action) = try OSFile.splice(from: &fromFile, to: &toFile, shouldStop: shouldStop)
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
                // Half-close this transfer direction; the reverse direction can continue.
                if shutdown(toFile.fileDescriptor, Int32(SHUT_WR)) != 0 {
                    log?.warning(
                        "failed to shut down writes",
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

#endif
