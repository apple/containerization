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

import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging

actor ManagedContainer {
    let id: String
    let initProcess: ManagedProcess

    private let _log: Logger
    private let _bundle: ContainerizationOCI.Bundle
    private var _execs: [String: ManagedProcess] = [:]

    var pid: Int32 {
        self.initProcess.pid
    }

    init(
        id: String,
        stdio: HostStdio,
        spec: ContainerizationOCI.Spec,
        log: Logger
    ) throws {
        let bundle = try ContainerizationOCI.Bundle.create(
            path: Self.craftBundlePath(id: id),
            spec: spec
        )
        log.info("created bundle with spec \(spec)")

        let initProcess = try ManagedProcess(
            id: id,
            stdio: stdio,
            bundle: bundle,
            owningPid: nil,
            log: log
        )
        log.info("created managed init process")

        self.initProcess = initProcess
        self.id = id
        self._bundle = bundle
        self._log = log
    }
}

extension ManagedContainer {
    private func ensureExecExists(_ id: String) throws {
        if self._execs[id] == nil {
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
        // Write the process config to the bundle, and pass this on
        // over to ManagedProcess to deal with.
        try self._bundle.createExecSpec(
            id: id,
            process: process
        )
        let process = try ManagedProcess(
            id: id,
            stdio: stdio,
            bundle: self._bundle,
            owningPid: self.initProcess.pid,
            log: self._log
        )
        self._execs[id] = process
    }

    func start(execID: String) async throws -> Int32 {
        let proc = try self.getExecOrInit(execID: execID)
        return try await ProcessSupervisor.default.start(process: proc)
    }

    func wait(execID: String) async throws -> Int32 {
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

    func deleteExec(id: String) throws {
        try ensureExecExists(id)
        do {
            try self._bundle.deleteExecSpec(id: id)
        } catch {
            self._log.error("failed to remove exec spec from filesystem: \(error)")
        }
        self._execs.removeValue(forKey: id)
    }

    func delete() throws {
        try self._bundle.delete()
    }

    func getExecOrInit(execID: String) throws -> ManagedProcess {
        if execID == self.id {
            return self.initProcess
        }
        guard let proc = self._execs[execID] else {
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
