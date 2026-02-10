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
import ContainerizationIO
import ContainerizationOS
import Foundation
import Logging
import Synchronization

package actor UnixSocketRelayManager {
    private let vm: any VirtualMachineInstance
    private var relays: [String: UnixSocketRelay]
    private let q: DispatchQueue
    private let log: Logger?

    init(vm: any VirtualMachineInstance, log: Logger? = nil) {
        self.vm = vm
        self.relays = [:]
        self.q = DispatchQueue(label: "com.apple.containerization.socket-relay")
        self.log = log
    }
}

extension UnixSocketRelayManager {
    func start(port: UInt32, socket: UnixSocketConfiguration) async throws {
        guard self.relays[socket.id] == nil else {
            throw ContainerizationError(
                .invalidState,
                message: "socket relay \(socket.id) already started"
            )
        }

        let relay = try UnixSocketRelay(
            port: port,
            socket: socket,
            vm: self.vm,
            queue: self.q,
            log: self.log
        )

        do {
            self.relays[socket.id] = relay
            try await relay.start()
        } catch {
            self.relays.removeValue(forKey: socket.id)
        }
    }

    func stop(socket: UnixSocketConfiguration) async throws {
        guard let storedRelay = self.relays.removeValue(forKey: socket.id) else {
            throw ContainerizationError(
                .notFound,
                message: "failed to stop socket relay"
            )
        }
        try storedRelay.stop()
    }

    func stopAll() async throws {
        for (_, relay) in self.relays {
            try relay.stop()
        }
    }
}

package final class UnixSocketRelay: Sendable {
    private let port: UInt32
    private let configuration: UnixSocketConfiguration
    private let log: Logger?
    private let vm: any VirtualMachineInstance
    private let q: DispatchQueue
    private let state: Mutex<State>

    private struct State {
        var activeRelays: [String: BidirectionalRelay] = [:]
        var t: Task<(), Never>? = nil
        var listener: VsockListener? = nil
    }

    init(
        port: UInt32,
        socket: UnixSocketConfiguration,
        vm: any VirtualMachineInstance,
        queue: DispatchQueue,
        log: Logger? = nil
    ) throws {
        self.port = port
        self.configuration = socket
        self.state = Mutex<State>(.init())
        self.vm = vm
        self.log = log
        self.q = queue
    }

    deinit {
        self.state.withLock { $0.t?.cancel() }
    }
}

extension UnixSocketRelay {
    func start() async throws {
        switch configuration.direction {
        case .outOf:
            try await setupHostVsockDial()
        case .into:
            try setupHostVsockListener()
        }
    }

    func stop() throws {
        try self.state.withLock {
            guard let t = $0.t else {
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to stop socket relay: relay has not been started"
                )
            }
            t.cancel()
            $0.t = nil
            for (_, relay) in $0.activeRelays {
                relay.stop()
            }
            $0.activeRelays.removeAll()

            switch configuration.direction {
            case .outOf:
                // If we created the host conn, lets unlink it also. It's possible it was
                // already unlinked if the relay failed earlier.
                try? FileManager.default.removeItem(at: self.configuration.destination)
            case .into:
                try $0.listener?.finish()
            }
        }
    }

    private func setupHostVsockDial() async throws {
        let hostConn = self.configuration.destination

        let socketType = try UnixType(
            path: hostConn.path,
            unlinkExisting: true
        )
        let hostSocket = try Socket(type: socketType)
        try hostSocket.listen()

        log?.info(
            "listening on host UDS",
            metadata: [
                "path": "\(hostConn.path)",
                "vport": "\(self.port)",
            ])
        let connectionStream = try hostSocket.acceptStream(closeOnDeinit: false)
        self.state.withLock {
            $0.t = Task {
                do {
                    for try await connection in connectionStream {
                        try await self.handleHostUnixConn(
                            hostConn: connection,
                            port: self.port,
                            vm: self.vm,
                            log: self.log
                        )
                    }
                } catch {
                    log?.error("failed in unix socket relay loop: \(error)")
                }
                try? FileManager.default.removeItem(at: hostConn)
            }
        }
    }

    private func setupHostVsockListener() throws {
        let hostPath = self.configuration.source
        let port = self.port
        let log = self.log

        let listener = try self.vm.listen(self.port)
        log?.info(
            "listening on guest vsock",
            metadata: [
                "path": "\(hostPath)",
                "vport": "\(port)",
            ])

        self.state.withLock {
            $0.listener = listener
            $0.t = Task {
                do {
                    defer { try? listener.finish() }
                    for await connection in listener {
                        try await self.handleGuestVsockConn(
                            vsockConn: connection,
                            hostConnectionPath: hostPath,
                            port: port,
                            log: log
                        )
                    }
                } catch {
                    log?.error("failed to setup relay between vsock \(port) and \(hostPath.path): \(error)")
                }
            }
        }
    }

    private func handleHostUnixConn(
        hostConn: ContainerizationOS.Socket,
        port: UInt32,
        vm: any VirtualMachineInstance,
        log: Logger?
    ) async throws {
        do {
            let guestConn = try await vm.dial(port)
            log?.debug(
                "initiating connection from host to guest",
                metadata: [
                    "vport": "\(port)",
                    "hostFd": "\(guestConn.fileDescriptor)",
                    "guestFd": "\(hostConn.fileDescriptor)",
                ])
            try await self.relay(
                hostConn: hostConn,
                guestFd: guestConn.fileDescriptor
            )
        } catch {
            log?.error("failed to relay between vsock \(port) and \(hostConn)")
            throw error
        }
    }

    private func handleGuestVsockConn(
        vsockConn: FileHandle,
        hostConnectionPath: URL,
        port: UInt32,
        log: Logger?
    ) async throws {
        let hostPath = hostConnectionPath.path
        let socketType = try UnixType(path: hostPath)
        let hostSocket = try Socket(
            type: socketType,
            closeOnDeinit: false
        )
        log?.debug(
            "initiating connection from guest to host",
            metadata: [
                "vport": "\(port)",
                "hostFd": "\(hostSocket.fileDescriptor)",
                "guestFd": "\(vsockConn.fileDescriptor)",
            ])
        try hostSocket.connect()

        do {
            try await self.relay(
                hostConn: hostSocket,
                guestFd: vsockConn.fileDescriptor
            )
        } catch {
            log?.error("failed to relay between vsock \(port) and \(hostPath)")
        }
    }

    private func relay(
        hostConn: Socket,
        guestFd: Int32
    ) async throws {
        let hostFd = hostConn.fileDescriptor

        let relayID = UUID().uuidString
        let relay = BidirectionalRelay(
            fd1: hostFd,
            fd2: guestFd,
            queue: self.q,
            log: self.log
        )

        self.state.withLock {
            $0.activeRelays[relayID] = relay
        }

        relay.start()
    }
}
