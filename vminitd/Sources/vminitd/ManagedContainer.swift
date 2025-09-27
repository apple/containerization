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

import Cgroup
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

actor ManagedContainer {
    let id: String
    let initProcess: ManagedProcess

    private let cgroupManager: Cgroup2Manager
    private let log: Logger
    private let bundle: ContainerizationOCI.Bundle
    private var execs: [String: ManagedProcess] = [:]
    private var namespaceWorker: NamespaceWorker?

    /// Worker child process that runs in container's namespace for filesystem operations
    private final class NamespaceWorker: @unchecked Sendable {
        private let containerID: String
        private let containerPID: Int32
        private var childPID: Int32?
        private var parentSocket: Int32?
        private var eventIDCounter: UInt32 = 0
        private let pendingEvents: Mutex<[UInt32: CheckedContinuation<Void, Error>]> = Mutex([:])
        private var responseReaderTask: Task<Void, Never>?
        private let shouldStop: Atomic<Bool> = Atomic(false)

        init(containerID: String, containerPID: Int32) {
            self.containerID = containerID
            self.containerPID = containerPID
        }

        func start() throws {
            guard childPID == nil else {
                throw ContainerizationError(.invalidState, message: "NamespaceWorker already started")
            }

            // Create socketpair for parent-child communication
            var sockets: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
                throw ContainerizationError(.internalError, message: "Failed to create socketpair: errno \(errno)")
            }

            let parentSocket = sockets[0]
            let childSocket = sockets[1]

            // Fork child process
            let pid = fork()
            guard pid >= 0 else {
                close(parentSocket)
                close(childSocket)
                throw ContainerizationError(.internalError, message: "Failed to fork: errno \(errno)")
            }

            if pid == 0 {
                // Child process
                close(parentSocket)
                runChildProcess(socket: childSocket)
                exit(0)
            } else {
                // Parent process
                close(childSocket)
                self.childPID = pid
                self.parentSocket = parentSocket

                // Wait for child to signal ready or failure
                var signal: UInt8 = 0
                let readResult = read(parentSocket, &signal, 1)

                if readResult != 1 {
                    // Child failed to send signal
                    close(parentSocket)
                    self.parentSocket = nil
                    var status: Int32 = 0
                    waitpid(pid, &status, 0)
                    self.childPID = nil
                    throw ContainerizationError(.internalError, message: "Child process failed to start")
                }

                if signal == 0xFF {
                    // Child failed to enter namespace
                    close(parentSocket)
                    self.parentSocket = nil
                    var status: Int32 = 0
                    waitpid(pid, &status, 0)
                    self.childPID = nil
                    throw ContainerizationError(.internalError, message: "Child process failed to enter container namespace")
                }

                if signal != 0xAA {
                    // Unexpected signal
                    close(parentSocket)
                    self.parentSocket = nil
                    var status: Int32 = 0
                    waitpid(pid, &status, 0)
                    self.childPID = nil
                    throw ContainerizationError(.internalError, message: "Child process sent unexpected signal: \(signal)")
                }

                // Start response reader task
                self.responseReaderTask = Task { [weak self] in
                    await self?.readChildResponses()
                }
            }
        }

        func enqueueEvent(path: String, eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType) async throws {
            guard let socket = parentSocket, !shouldStop.load(ordering: .relaxed) else {
                throw ContainerizationError(.invalidState, message: "NamespaceWorker not running")
            }

            let eventID = eventIDCounter
            eventIDCounter += 1

            // Store continuation for this event
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingEvents.withLock { events in
                    events[eventID] = continuation
                }

                // Send event to child process
                do {
                    try sendEventToChild(socket: socket, eventID: eventID, path: path, eventType: eventType)
                } catch {
                    // Remove from pending events if send failed
                    _ = pendingEvents.withLock { events in
                        events.removeValue(forKey: eventID)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }

        func stop() {
            shouldStop.store(true, ordering: .relaxed)

            // Cancel response reader task
            responseReaderTask?.cancel()
            responseReaderTask = nil

            // Close parent socket
            if let socket = parentSocket {
                close(socket)
                parentSocket = nil
            }

            // Terminate child process
            if let pid = childPID {
                #if canImport(Musl)
                Musl.kill(pid, SIGTERM)
                #elseif canImport(Glibc)
                Glibc.kill(pid, SIGTERM)
                #endif

                // Wait for child to exit
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                childPID = nil
            }

            // Cancel all pending events
            pendingEvents.withLock { events in
                for (_, continuation) in events {
                    continuation.resume(throwing: ContainerizationError(.cancelled, message: "NamespaceWorker stopped"))
                }
                events.removeAll()
            }
        }

        private func runChildProcess(socket: Int32) {
            // Enter container namespace
            do {
                try enterContainerNamespace()
            } catch {
                // Signal parent that namespace entry failed, then exit
                var failureResponse: UInt8 = 0xFF  // Special failure signal
                _ = write(socket, &failureResponse, 1)
                close(socket)
                exit(1)
            }

            // Signal parent that we're ready
            var readySignal: UInt8 = 0xAA  // Ready signal
            guard write(socket, &readySignal, 1) == 1 else {
                close(socket)
                exit(1)
            }

            // Child event loop
            while true {
                do {
                    // Read event from parent
                    guard let (eventID, path, eventType) = try readEventFromParent(socket: socket) else {
                        break  // Parent closed socket
                    }

                    // Process filesystem event
                    var success: UInt8 = 1
                    do {
                        try generateSyntheticInotifyEvent(path: path, eventType: eventType)
                    } catch {
                        success = 0
                    }

                    // Send response to parent
                    try sendResponseToParent(socket: socket, eventID: eventID, success: success)
                } catch {
                    break
                }
            }

            close(socket)
        }

        private func readChildResponses() async {
            guard let socket = parentSocket else { return }

            while !shouldStop.load(ordering: .relaxed) {
                do {
                    // Read response from child
                    guard let (eventID, success) = try readResponseFromChild(socket: socket) else {
                        break  // Socket closed
                    }

                    // Resume the corresponding continuation
                    pendingEvents.withLock { events in
                        if let continuation = events.removeValue(forKey: eventID) {
                            if success == 1 {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: ContainerizationError(.internalError, message: "Child process failed to process filesystem event"))
                            }
                        }
                    }
                } catch {
                    break
                }
            }
        }

        private func sendEventToChild(socket: Int32, eventID: UInt32, path: String, eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType) throws {
            let pathData = path.data(using: .utf8) ?? Data()
            let pathLen = UInt32(pathData.count)
            let eventTypeValue = UInt32(eventType.rawValue)

            // Binary protocol: [event_type:4][path_len:4][path:N][event_id:4]
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
            // Read event_type:4
            var eventTypeValue: UInt32 = 0
            guard read(socket, &eventTypeValue, 4) == 4 else { return nil }
            eventTypeValue = UInt32(bigEndian: eventTypeValue)

            // Read path_len:4
            var pathLen: UInt32 = 0
            guard read(socket, &pathLen, 4) == 4 else { return nil }
            pathLen = UInt32(bigEndian: pathLen)

            // Read path:N
            let pathData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(pathLen))
            defer { pathData.deallocate() }
            guard read(socket, pathData, Int(pathLen)) == pathLen else { return nil }
            let pathBytes = Data(bytes: pathData, count: Int(pathLen))
            guard let path = String(data: pathBytes, encoding: .utf8) else { return nil }

            // Read event_id:4
            var eventID: UInt32 = 0
            guard read(socket, &eventID, 4) == 4 else { return nil }
            eventID = UInt32(bigEndian: eventID)

            guard let eventType = Com_Apple_Containerization_Sandbox_V3_FileSystemEventType(rawValue: Int(eventTypeValue)) else {
                return nil
            }

            return (eventID, path, eventType)
        }

        private func sendResponseToParent(socket: Int32, eventID: UInt32, success: UInt8) throws {
            // Binary protocol: [event_id:4][success:1]
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

        private func readResponseFromChild(socket: Int32) throws -> (UInt32, UInt8)? {
            // Read event_id:4
            var eventID: UInt32 = 0
            guard read(socket, &eventID, 4) == 4 else { return nil }
            eventID = UInt32(bigEndian: eventID)

            // Read success:1
            var success: UInt8 = 0
            guard read(socket, &success, 1) == 1 else { return nil }

            return (eventID, success)
        }

        private func enterContainerNamespace() throws {
            let nsPath = "/proc/\(containerPID)/ns/mnt"
            let vmNsPath = "/proc/self/ns/mnt"

            guard FileManager.default.fileExists(atPath: nsPath) else {
                throw ContainerizationError(.internalError, message: "Namespace file does not exist: \(nsPath)")
            }

            // Compare namespace inodes to see if they're the same
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
                    // Skip setns() since we're already in the right namespace
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
    }

    var pid: Int32? {
        self.initProcess.pid
    }

    init(
        id: String,
        stdio: HostStdio,
        spec: ContainerizationOCI.Spec,
        log: Logger
    ) throws {
        var cgroupsPath: String
        if let cgPath = spec.linux?.cgroupsPath {
            cgroupsPath = cgPath
        } else {
            cgroupsPath = "/container/\(id)"
        }

        let bundle = try ContainerizationOCI.Bundle.create(
            path: Self.craftBundlePath(id: id),
            spec: spec
        )
        log.debug("created bundle with spec \(spec)")

        let cgManager = Cgroup2Manager(
            group: URL(filePath: cgroupsPath),
            logger: log
        )
        try cgManager.create()

        do {
            try cgManager.toggleAllAvailableControllers(enable: true)

            let initProcess = try ManagedProcess(
                id: id,
                stdio: stdio,
                bundle: bundle,
                cgroupManager: cgManager,
                owningPid: nil,
                log: log
            )
            log.info("created managed init process")

            self.cgroupManager = cgManager
            self.initProcess = initProcess
            self.id = id
            self.bundle = bundle
            self.log = log

            // Initialize namespace worker - will be started after process starts
            self.namespaceWorker = nil
        } catch {
            try? cgManager.delete()
            throw error
        }
    }
}

extension ManagedContainer {
    private func ensureExecExists(_ id: String) throws {
        if self.execs[id] == nil {
            throw ContainerizationError(
                .invalidState,
                message: "exec \(id) does not exist in container \(self.id)"
            )
        }
    }

    /// Start namespace worker child process after container process starts
    private func startNamespaceWorker() throws {
        let pid = self.initProcess.pid
        guard pid > 0 else {
            throw ContainerizationError(.invalidState, message: "Container process not started")
        }

        let worker = NamespaceWorker(containerID: self.id, containerPID: pid)
        try worker.start()
        self.namespaceWorker = worker
    }

    /// Execute filesystem event using dedicated namespace child process
    func executeFileSystemEvent(path: String, eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType) async throws {
        guard let worker = self.namespaceWorker else {
            throw ContainerizationError(.invalidState, message: "Namespace worker not started for container \(self.id)")
        }
        try await worker.enqueueEvent(path: path, eventType: eventType)
    }

    func createExec(
        id: String,
        stdio: HostStdio,
        process: ContainerizationOCI.Process
    ) throws {
        log.debug("creating exec process with \(process)")

        // Write the process config to the bundle, and pass this on
        // over to ManagedProcess to deal with.
        try self.bundle.createExecSpec(
            id: id,
            process: process
        )
        let process = try ManagedProcess(
            id: id,
            stdio: stdio,
            bundle: self.bundle,
            owningPid: self.initProcess.pid,
            log: self.log
        )
        self.execs[id] = process
    }

    func start(execID: String) async throws -> Int32 {
        let proc = try self.getExecOrInit(execID: execID)
        let pid = try await ProcessSupervisor.default.start(process: proc)

        // Start namespace worker child process if this is the init process
        if execID == self.id {
            try self.startNamespaceWorker()
        }

        return pid
    }

    func wait(execID: String) async throws -> ManagedProcess.ExitStatus {
        let proc = try self.getExecOrInit(execID: execID)
        return await proc.wait()
    }

    func kill(execID: String, _ signal: Int32) throws {
        let proc = try self.getExecOrInit(execID: execID)
        try proc.kill(signal)
    }

    func resize(execID: String, size: Terminal.Size) throws {
        let proc = try self.getExecOrInit(execID: execID)
        try proc.resize(size: size)
    }

    func closeStdin(execID: String) throws {
        let proc = try self.getExecOrInit(execID: execID)
        try proc.closeStdin()
    }

    func deleteExec(id: String) throws {
        try ensureExecExists(id)
        do {
            try self.bundle.deleteExecSpec(id: id)
        } catch {
            self.log.error("failed to remove exec spec from filesystem: \(error)")
        }
        self.execs.removeValue(forKey: id)
    }

    func delete() throws {
        // Stop namespace worker child process
        self.namespaceWorker?.stop()
        self.namespaceWorker = nil

        try self.bundle.delete()
        try self.cgroupManager.delete(force: true)
    }

    func stats() throws -> Cgroup2Stats {
        try self.cgroupManager.stats()
    }

    func getExecOrInit(execID: String) throws -> ManagedProcess {
        if execID == self.id {
            return self.initProcess
        }
        guard let proc = self.execs[execID] else {
            throw ContainerizationError(
                .invalidState,
                message: "exec \(execID) does not exist in container \(self.id)"
            )
        }
        return proc
    }
}

extension ContainerizationOCI.Bundle {
    func createExecSpec(id: String, process: ContainerizationOCI.Process) throws {
        let specDir = self.path.appending(path: "execs/\(id)")

        let fm = FileManager.default
        try fm.createDirectory(
            atPath: specDir.path,
            withIntermediateDirectories: true
        )

        let specData = try JSONEncoder().encode(process)
        let processConfigPath = specDir.appending(path: "process.json")
        try specData.write(to: processConfigPath)
    }

    func getExecSpecPath(id: String) -> URL {
        self.path.appending(path: "execs/\(id)/process.json")
    }

    func deleteExecSpec(id: String) throws {
        let specDir = self.path.appending(path: "execs/\(id)")

        let fm = FileManager.default
        try fm.removeItem(at: specDir)
    }
}

extension ManagedContainer {
    static func craftBundlePath(id: String) -> URL {
        URL(fileURLWithPath: "/run/container").appending(path: id)
    }
}
