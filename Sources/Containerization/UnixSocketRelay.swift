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

import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import Synchronization

package final class UnixSocketRelay: Sendable {
    private let port: UInt32
    private let configuration: UnixSocketConfiguration
    private let vm: any VirtualMachineInstance
    private let log: Logger?
    private let state = Mutex(State())

    private struct PathIdentity {
        let device: dev_t
        let inode: ino_t
    }

    private enum Lifecycle { case idle, running, stopped }

    private struct State {
        var lifecycle = Lifecycle.idle
        var activeRelays: [UUID: BidirectionalRelay] = [:]
        var task: Task<Void, Never>?
        var listener: VsockListener?
        var hostSocket: Socket?
        var hostPathIdentity: PathIdentity?
    }

    init(port: UInt32, socket: UnixSocketConfiguration, vm: any VirtualMachineInstance, log: Logger? = nil) throws {
        self.port = port
        self.configuration = socket
        self.vm = vm
        self.log = log
    }

    deinit { try? stop() }

    func start() async throws {
        try state.withLock {
            guard $0.lifecycle == .idle else { throw ContainerizationError(.invalidState, message: "socket relay is already started or stopped") }
            $0.lifecycle = .running
        }
        do {
            switch configuration.direction {
            case .outOf: try setupHostVsockDial()
            case .into: try setupHostVsockListener()
            }
        } catch {
            try? stop()
            throw error
        }
    }

    /// Stop is terminal; pending acquisitions cannot install another relay.
    func stop() throws {
        let previous = state.withLock { state in
            let previous = state
            state = State(lifecycle: .stopped)
            return previous
        }
        previous.task?.cancel()
        try? previous.hostSocket?.close()
        for relay in previous.activeRelays.values { relay.stop() }
        try previous.listener?.cancelAndDiscard()
        if let identity = previous.hostPathIdentity {
            // If we created the host conn, lets unlink it also. It's possible it was
            // already unlinked if the relay failed earlier.
            removeHostPath(ifMatches: identity)
        }
    }

    private func setupHostVsockDial() throws {
        let path = configuration.destination
        let hostSocket = try Socket(type: UnixType(path: path.path, unlinkExisting: true))
        try hostSocket.listen()
        var info = stat()
        guard lstat(path.path, &info) == 0 else { throw POSIXError.fromErrno() }
        let identity = PathIdentity(device: info.st_dev, inode: info.st_ino)
        let connections: AsyncThrowingStream<Socket, any Error>
        do { connections = try hostSocket.acceptStream() } catch {
            removeHostPath(ifMatches: identity)
            throw error
        }
        let log = self.log
        let installed = state.withLock { state in
            guard state.lifecycle == .running else { return false }
            state.hostSocket = hostSocket
            state.hostPathIdentity = identity
            state.task = Task { [weak self] in
                do {
                    for try await connection in connections {
                        guard !Task.isCancelled else { break }
                        do {
                            guard let self else { break }
                            try await self.handleHostUnixConn(connection)
                        } catch {
                            if Task.isCancelled { break }
                            log?.error("failed to set up host to guest relay: \(error)")
                        }
                    }
                } catch {
                    if !Task.isCancelled { log?.error("failed in unix socket relay loop: \(error)") }
                }
                try? hostSocket.close()
                self?.removeHostPath(ifMatches: identity)
            }
            return true
        }
        if !installed {
            try? hostSocket.close()
            removeHostPath(ifMatches: identity)
        }
    }

    private func removeHostPath(ifMatches identity: PathIdentity) {
        var current = stat()
        let path = configuration.destination.path
        guard lstat(path, &current) == 0, current.st_dev == identity.device, current.st_ino == identity.inode else { return }
        _ = unlink(path)
    }

    private func setupHostVsockListener() throws {
        let listener = try vm.listen(port)
        let owned = vm is any OwnedVsockDialing
        let log = self.log
        let installed = state.withLock { state in
            guard state.lifecycle == .running else { return false }
            state.listener = listener
            state.task = Task { [weak self] in
                defer { try? listener.cancelAndDiscard() }
                if owned {
                    do {
                        while let connection = try await listener.nextOwned() {
                            guard !Task.isCancelled, let self else { break }
                            do { try self.handleGuestVsockConn(connection) } catch { log?.error("failed to set up guest to host relay: \(error)") }
                        }
                    } catch {
                        if !Task.isCancelled { log?.error("failed in vsock relay loop: \(error)") }
                    }
                } else {
                    for await connection in listener {
                        guard !Task.isCancelled, let self else {
                            try? connection.close()
                            break
                        }
                        do { try self.handleLegacyGuestConn(connection) } catch { log?.error("failed to set up legacy guest to host relay: \(error)") }
                    }
                }
            }
            return true
        }
        if !installed { try listener.cancelAndDiscard() }
    }

    private func handleHostUnixConn(_ host: Socket) async throws {
        if let backend = vm as? any OwnedVsockDialing {
            let guest = try await backend.dialOwned(port)
            try Task.checkCancellation()
            try install(BidirectionalRelay(descriptor1: host.takeDescriptor(), descriptor2: guest, log: log))
        } else {
            let guest = try await Self.adoptDuplicate(of: vm.dial(port))
            try Task.checkCancellation()
            try install(BidirectionalRelay(descriptor1: host.takeDescriptor(), descriptor2: guest, log: log))
        }
    }

    private func handleGuestVsockConn(_ guest: consuming DescriptorTransfer) throws {
        let host = try Socket(type: UnixType(path: configuration.source.path))
        try host.connect()
        try install(BidirectionalRelay(descriptor1: host.takeDescriptor(), descriptor2: guest, log: log))
    }

    private func handleLegacyGuestConn(_ guest: FileHandle) throws {
        try handleGuestVsockConn(Self.adoptDuplicate(of: guest))
    }

    /// A custom backend's `FileHandle` may still close its descriptor, so the relay owns a duplicate.
    private static func adoptDuplicate(of guest: FileHandle) throws -> DescriptorTransfer {
        defer { try? guest.close() }
        let fd = fcntl(guest.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw POSIXError.fromErrno() }
        return DescriptorTransfer(adopting: fd)
    }

    private func install(_ relay: BidirectionalRelay) throws {
        let identity = UUID()
        let installed = state.withLock { state in
            guard state.lifecycle == .running else { return false }
            state.activeRelays[identity] = relay
            return true
        }
        guard installed else {
            relay.stop()
            throw CancellationError()
        }
        do { try relay.start() } catch {
            relay.stop()
            state.withLock { $0.activeRelays[identity] = nil }
            throw error
        }
        Task { [weak self] in
            await relay.waitForCompletion()
            self?.state.withLock { $0.activeRelays[identity] = nil }
        }
    }
}
