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

import ContainerizationError
import ContainerizationIO
import ContainerizationOS
import Foundation
import Logging
import Synchronization

package actor UnixSocketRelayManager {
    private let vm: any VirtualMachineInstance
    private var relays: [String: SocketRelay]
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

        let socketRelay = try SocketRelay(
            port: port,
            socket: socket,
            vm: self.vm,
            queue: self.q,
            log: self.log
        )

        do {
            self.relays[socket.id] = socketRelay
            try await socketRelay.start()
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

package final class SocketRelay: Sendable {
    private let port: UInt32
    private let configuration: UnixSocketConfiguration
    private let log: Logger?
    private let vm: any VirtualMachineInstance
    private let q: DispatchQueue
    private let state: Mutex<State>

    private struct State {
        var relaySources: [String: ConnectionSources] = [:]
        var t: Task<(), Never>? = nil
    }

    // `DispatchSourceRead` is thread-safe.
    private struct ConnectionSources: @unchecked Sendable {
        let hostSource: DispatchSourceRead
        let guestSource: DispatchSourceRead
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

extension SocketRelay {
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
            $0.relaySources.removeAll()
        }

        switch configuration.direction {
        case .outOf:
            // If we created the host conn, lets unlink it also. It's possible it was
            // already unlinked if the relay failed earlier.
            try? FileManager.default.removeItem(at: self.configuration.destination)
        case .into:
            try self.vm.stopListen(self.port)
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

        let connectionStream = try self.vm.listen(self.port)
        self.state.withLock {
            $0.t = Task {
                do {
                    defer { connectionStream.finish() }
                    for await connection in connectionStream.connections {
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
        let connSource = DispatchSource.makeReadSource(
            fileDescriptor: hostConn.fileDescriptor,
            queue: self.q
        )
        let vsockConnectionSource = DispatchSource.makeReadSource(
            fileDescriptor: guestFd,
            queue: self.q
        )

        let pairID = UUID().uuidString
        self.state.withLock {
            $0.relaySources[pairID] = ConnectionSources(
                hostSource: connSource,
                guestSource: vsockConnectionSource
            )
        }

        // `buf1` isn't used concurrently.
        nonisolated(unsafe) let buf1 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))
        connSource.setEventHandler {
            Self.fdCopyHandler(
                buffer: buf1,
                source: connSource,
                from: hostConn.fileDescriptor,
                to: guestFd
            )
        }

        nonisolated(unsafe) let buf2 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))
        // `buf2` isn't used concurrently.
        vsockConnectionSource.setEventHandler {
            Self.fdCopyHandler(
                buffer: buf2,
                source: vsockConnectionSource,
                from: guestFd,
                to: hostConn.fileDescriptor
            )
        }

        connSource.setCancelHandler {
            if !connSource.isCancelled {
                connSource.cancel()
            }
            if !vsockConnectionSource.isCancelled {
                vsockConnectionSource.cancel()
            }
            try? hostConn.close()
        }

        vsockConnectionSource.setCancelHandler {
            if !vsockConnectionSource.isCancelled {
                vsockConnectionSource.cancel()
            }
            if !connSource.isCancelled {
                connSource.cancel()
            }
            close(guestFd)
        }

        connSource.activate()
        vsockConnectionSource.activate()
    }

    private static func fdCopyHandler(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        source: DispatchSourceRead,
        from sourceFd: Int32,
        to destinationFd: Int32,
        log: Logger? = nil
    ) {
        if source.data == 0 {
            if !source.isCancelled {
                source.cancel()
            }
            return
        }

        do {
            try self.fileDescriptorCopy(
                buffer: buffer,
                size: source.data,
                from: sourceFd,
                to: destinationFd
            )
        } catch {
            log?.error("file descriptor copy failed \(error)")
            if !source.isCancelled {
                source.cancel()
            }
        }
    }

    private static func fileDescriptorCopy(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        size: UInt,
        from sourceFd: Int32,
        to destinationFd: Int32
    ) throws {
        let bufferSize = buffer.count
        var readBytesRemaining = min(Int(size), bufferSize)

        guard let baseAddr = buffer.baseAddress else {
            throw ContainerizationError(
                .invalidState,
                message: "buffer has no base address"
            )
        }

        while readBytesRemaining > 0 {
            let readResult = read(sourceFd, baseAddr, min(bufferSize, readBytesRemaining))
            if readResult <= 0 {
                throw ContainerizationError(
                    .internalError,
                    message: "missing pointer base address"
                )
            }
            readBytesRemaining -= readResult

            var writeBytesRemaining = readResult
            while writeBytesRemaining > 0 {
                let writeResult = write(destinationFd, baseAddr, writeBytesRemaining)
                if writeResult <= 0 {
                    throw ContainerizationError(
                        .internalError,
                        message: "zero byte write or error in socket relay"
                    )
                }
                writeBytesRemaining -= writeResult
            }
        }
    }
}
