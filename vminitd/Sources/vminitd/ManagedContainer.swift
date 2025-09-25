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

    /// Worker thread that runs in container's namespace for filesystem operations
    private final class NamespaceWorker: @unchecked Sendable {
        private let containerID: String
        private let containerPID: Int32
        private var workerThread: Thread?
        private let eventQueue: Mutex<[FileSystemEvent]> = Mutex([])
        private let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        private let shouldStop: Atomic<Bool> = Atomic(false)

        struct FileSystemEvent: Sendable {
            let path: String
            let eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType
            let completion: @Sendable (Result<Void, Error>) -> Void
        }

        init(containerID: String, containerPID: Int32) {
            self.containerID = containerID
            self.containerPID = containerPID
        }

        func start() throws {
            guard workerThread == nil else {
                throw ContainerizationError(.invalidState, message: "NamespaceWorker already started")
            }

            let thread = Thread { [weak self] in
                self?.runWorkerLoop()
            }
            thread.name = "namespace-worker-\(containerID)"
            workerThread = thread
            thread.start()
        }

        func enqueueEvent(path: String, eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType) async throws {
            try await withCheckedThrowingContinuation { continuation in
                let event = FileSystemEvent(
                    path: path,
                    eventType: eventType,
                    completion: { @Sendable result in
                        continuation.resume(with: result)
                    }
                )

                eventQueue.withLock { (queue: inout [FileSystemEvent]) in
                    queue.append(event)
                }
                semaphore.signal()
            }
        }

        func stop() {
            shouldStop.store(true, ordering: .relaxed)
            semaphore.signal()  // Wake up the worker thread
            workerThread?.cancel()
            workerThread = nil
        }

        private func runWorkerLoop() {
            // Enter container namespace
            do {
                try enterContainerNamespace()
            } catch {
                return
            }

            // Worker loop
            while !shouldStop.load(ordering: .relaxed) {
                semaphore.wait()

                // Check stop condition again after waking up
                if shouldStop.load(ordering: .relaxed) {
                    break
                }

                // Process all queued events
                let events = eventQueue.withLock { (queue: inout [FileSystemEvent]) -> [FileSystemEvent] in
                    let currentEvents = Array(queue)
                    queue.removeAll()
                    return currentEvents
                }

                for event in events {
                    do {
                        try generateSyntheticInotifyEvent(path: event.path, eventType: event.eventType)
                        event.completion(.success(()))
                    } catch {
                        event.completion(.failure(error))
                    }
                }
            }
        }

        private func enterContainerNamespace() throws {
            let nsPath = "/proc/\(containerPID)/ns/mnt"
            let fd = open(nsPath, O_RDONLY)
            guard fd >= 0 else {
                throw ContainerizationError(.internalError, message: "Failed to open namespace file: \(nsPath)")
            }
            defer { _ = close(fd) }

            guard setns(fd, CLONE_NEWNS) == 0 else {
                throw ContainerizationError(.internalError, message: "Failed to setns to mount namespace: \(errno)")
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

    /// Start namespace worker thread after container process starts
    private func startNamespaceWorker() throws {
        let pid = self.initProcess.pid
        guard pid > 0 else {
            throw ContainerizationError(.invalidState, message: "Container process not started")
        }

        let worker = NamespaceWorker(containerID: self.id, containerPID: pid)
        try worker.start()
        self.namespaceWorker = worker
    }

    /// Execute filesystem event using dedicated namespace thread
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

        // Start namespace worker thread if this is the init process
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
        // Stop namespace worker thread
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
