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

package final class UnixSocketRelay: Sendable {
    private let port: UInt32
    private let configuration: UnixSocketConfiguration
    private let vm: any VirtualMachineInstance
    private let queue: DispatchQueue
    private let log: Logger?
    private let state: Mutex<State>

    private struct ActiveRelay: Sendable {
        let relay: BidirectionalRelay
        let guestConnection: VsockConnection
    }

    private struct State {
        var activeRelays: [String: ActiveRelay] = [:]
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
        self.vm = vm
        self.queue = queue
        self.log = log
        self.state = Mutex<State>(.init())
    }

    deinit {
        state.withLock { $0.t?.cancel() }
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
        try state.withLock {
            guard let t = $0.t else {
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to stop socket relay: relay has not been started"
                )
            }
            t.cancel()
            $0.t = nil
            for (_, activeRelay) in $0.activeRelays {
                activeRelay.relay.stop()
            }

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
        let hostConn = configuration.destination

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
                "vport": "\(port)",
            ])
        let connectionStream = try hostSocket.acceptStream(closeOnDeinit: false)
        state.withLock {
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
        let hostPath = configuration.source

        let listener = try vm.listen(port)
        log?.info(
            "listening on guest vsock",
            metadata: [
                "path": "\(hostPath)",
                "vport": "\(port)",
            ])

        state.withLock {
            $0.listener = listener
            $0.t = Task {
                do {
                    defer { try? listener.finish() }
                    for await connection in listener {
                        try await self.handleGuestVsockConn(
                            vsockConn: connection,
                            hostConnectionPath: hostPath,
                            port: self.port,
                            log: self.log
                        )
                    }
                } catch {
                    self.log?.error("failed to setup relay between vsock \(self.port) and \(hostPath.path): \(error)")
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
                    "hostFd": "\(hostConn.fileDescriptor)",
                    "guestFd": "\(guestConn.fileDescriptor)",
                ])
            try await self.relay(
                hostConn: hostConn,
                guestConn: guestConn
            )
        } catch {
            log?.error("failed to relay between vsock \(port) and \(hostConn)")
            throw error
        }
    }

    private func handleGuestVsockConn(
        vsockConn: VsockConnection,
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
                guestConn: vsockConn
            )
        } catch {
            log?.error("failed to relay between vsock \(port) and \(hostPath)")
        }
    }

    private func relay(
        hostConn: Socket,
        guestConn: VsockConnection
    ) async throws {
        let hostFd = hostConn.fileDescriptor
        let guestFd = dup(guestConn.fileDescriptor)
        if guestFd == -1 {
            throw POSIXError.fromErrno()
        }

        let relayID = UUID().uuidString
        let relay = BidirectionalRelay(
            fd1: hostFd,
            fd2: guestFd,
            queue: queue,
            log: log
        )

        state.withLock {
            // Retain the original connection until the relay has fully completed.
            // The relay owns its duplicated fd and will close it itself.
            $0.activeRelays[relayID] = ActiveRelay(
                relay: relay,
                guestConnection: guestConn
            )
        }

        relay.start()

        Task {
            await relay.waitForCompletion()
            let _ = self.state.withLock {
                $0.activeRelays.removeValue(forKey: relayID)
            }
        }
    }
}
