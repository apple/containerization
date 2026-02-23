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

#if os(macOS)
import Foundation
import Logging
import Virtualization
import ContainerizationError

extension VZVirtualMachine {
    nonisolated func connect(queue: DispatchQueue, port: UInt32) async throws -> VZVirtioSocketConnection {
        try await withCheckedThrowingContinuation { cont in
            queue.sync {
                guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                    let error = ContainerizationError(.invalidArgument, message: "no vsock device")
                    cont.resume(throwing: error)
                    return
                }
                vsock.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        // `conn` isn't used concurrently.
                        nonisolated(unsafe) let conn = conn
                        cont.resume(returning: conn)
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func listen(queue: DispatchQueue, port: UInt32, listener: VZVirtioSocketListener) throws {
        try queue.sync {
            guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                throw ContainerizationError(.invalidArgument, message: "no vsock device")
            }
            vsock.setSocketListener(listener, forPort: port)
        }
    }

    func removeListener(queue: DispatchQueue, port: UInt32) throws {
        try queue.sync {
            guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock device to remove"
                )
            }
            vsock.removeSocketListener(forPort: port)
        }
    }

    func start(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.start { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func stop(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.stop { error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func pause(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.pause { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func resume(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.resume { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }
}

extension VZVirtualMachine {
    func waitForAgent(queue: DispatchQueue) async throws -> (FileHandle, VsockTransport) {
        let agentConnectionRetryCount: Int = 150
        let agentConnectionSleepDuration: Duration = .milliseconds(20)

        for _ in 0...agentConnectionRetryCount {
            do {
                let conn = try await self.connect(queue: queue, port: Vminitd.port)
                let handle = try conn.dupFileDescriptor()
                return (handle, VsockTransport(conn))
            } catch {
                try await Task.sleep(for: agentConnectionSleepDuration)
                continue
            }
        }
        throw ContainerizationError(.invalidArgument, message: "no connection to agent socket")
    }
}

extension VZVirtioSocketConnection {
    /// Duplicates the file descriptor and immediately closes the connection.
    ///
    /// Only safe when the returned fd is used synchronously before any
    /// suspension point. For deferred use (e.g., gRPC/NIO), use
    /// ``dupFileDescriptor()`` and keep the connection alive via
    /// ``VsockTransport``.
    func dupHandle() throws -> FileHandle {
        let fd = dup(self.fileDescriptor)
        if fd == -1 {
            throw POSIXError.fromErrno()
        }
        self.close()
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    /// Duplicates the connection's file descriptor without closing the connection.
    ///
    /// The caller must keep the `VZVirtioSocketConnection` alive until the dup'd
    /// descriptor is no longer needed. The Virtualization framework tears down the
    /// vsock endpoint when the connection is closed, which invalidates dup'd
    /// descriptors.
    func dupFileDescriptor() throws -> FileHandle {
        let fd = dup(self.fileDescriptor)
        if fd == -1 {
            throw POSIXError.fromErrno()
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }
}

#endif
