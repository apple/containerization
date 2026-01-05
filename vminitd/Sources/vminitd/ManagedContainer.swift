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

import Cgroup
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging

actor ManagedContainer {
    let id: String
    let initProcess: any ContainerProcess

    private let cgroupManager: Cgroup2Manager
    private let log: Logger
    private let bundle: ContainerizationOCI.Bundle
    private let needsCgroupCleanup: Bool
    private var execs: [String: any ContainerProcess] = [:]

    var pid: Int32? {
        self.initProcess.pid
    }

    init(
        id: String,
        stdio: HostStdio,
        spec: ContainerizationOCI.Spec,
        ociRuntimePath: String? = nil,
        log: Logger
    ) async throws {
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

            let initProcess: any ContainerProcess

            if let runtimePath = ociRuntimePath {
                // Use runc runtime
                let runc = ProcessSupervisor.default.getRuncWithReaper(
                    Runc(
                        command: runtimePath,
                        root: "/run/runc"
                    )
                )
                initProcess = try RuncProcess(
                    id: id,
                    stdio: stdio,
                    bundle: bundle,
                    runc: runc,
                    log: log
                )
                self.needsCgroupCleanup = false
                log.info("created runc init process with runtime: \(runtimePath)")
            } else {
                // Use vmexec runtime
                initProcess = try ManagedProcess(
                    id: id,
                    stdio: stdio,
                    bundle: bundle,
                    cgroupManager: cgManager,
                    owningPid: nil,
                    log: log
                )
                self.needsCgroupCleanup = true
                log.info("created vmexec init process")
            }

            self.cgroupManager = cgManager
            self.initProcess = initProcess
            self.id = id
            self.bundle = bundle
            self.log = log
        } catch {
            try? cgManager.delete()
            throw error
        }
    }
}

extension ManagedContainer {
    // removeCgroupWithRetry will remove a cgroup path handling EAGAIN and EBUSY errors and
    // retrying the remove after an exponential timeout
    private func removeCgroupWithRetry() async throws {
        var delay = 10  // 10ms
        let maxRetries = 5

        for i in 0..<maxRetries {
            if i != 0 {
                try await Task.sleep(for: .milliseconds(delay))
                delay *= 2
            }

            do {
                try self.cgroupManager.delete(force: true)
                return
            } catch let error as Cgroup2Manager.Error {
                guard case .errno(let errnoValue, let message) = error,
                    errnoValue == EBUSY || errnoValue == EAGAIN
                else {
                    throw error
                }
                self.log.warning(
                    "cgroup deletion failed with EBUSY/EAGAIN, retrying",
                    metadata: [
                        "attempt": "\(i + 1)",
                        "delay": "\(delay)",
                        "errno": "\(errnoValue)",
                        "context": "\(message)",
                    ])
                continue
            }
        }

        throw ContainerizationError(
            .internalError,
            message: "cgroups: unable to remove cgroup after \(maxRetries) retries"
        )
    }

    private func ensureExecExists(_ id: String) throws {
        if self.execs[id] == nil {
            throw ContainerizationError(
                .invalidState,
                message: "exec \(id) does not exist in container \(self.id)"
            )
        }
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
        return try await ProcessSupervisor.default.start(process: proc)
    }

    func wait(execID: String) async throws -> ContainerExitStatus {
        let proc = try self.getExecOrInit(execID: execID)
        return await proc.wait()
    }

    func kill(execID: String, _ signal: Int32) async throws {
        let proc = try self.getExecOrInit(execID: execID)
        try await proc.kill(signal)
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

    func delete() async throws {
        // Delete the init process if it's a RuncProcess
        try await self.initProcess.delete()

        // Delete the bundle and cgroup
        try self.bundle.delete()
        if self.needsCgroupCleanup {
            try await self.removeCgroupWithRetry()
        }
    }

    func stats() throws -> Cgroup2Stats {
        try self.cgroupManager.stats()
    }

    func getExecOrInit(execID: String) throws -> any ContainerProcess {
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
