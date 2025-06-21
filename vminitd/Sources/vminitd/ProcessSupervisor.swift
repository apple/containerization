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

import ContainerizationOS
import Foundation
import Logging

actor ProcessSupervisor {
    private let queue: DispatchQueue
    // `DispatchSourceSignal` is thread-safe.
    private nonisolated(unsafe) let source: DispatchSourceSignal
    private var processes = [ManagedProcess]()

    var log: Logger?

    func setLog(_ log: Logger?) {
        self.log = log
    }

    static let `default` = ProcessSupervisor()

    let poller: Epoll

    private init() {
        let queue = DispatchQueue(label: "process-supervisor")
        self.source = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
        self.queue = queue
        self.poller = try! Epoll()
        let t = Thread {
            try! self.poller.run()
        }
        t.start()
    }

    func ready() {
        self.source.setEventHandler {
            do {
                self.log?.debug("received SIGCHLD, reaping processes")
                try self.handleSignal()
            } catch {
                self.log?.error("reaping processes failed", metadata: ["error": "\(error)"])
            }
        }
        self.source.resume()
    }

    private func handleSignal() throws {
        dispatchPrecondition(condition: .onQueue(queue))

        self.log?.debug("starting to wait4 processes")
        let exited = Reaper.reap()
        self.log?.debug("finished wait4 of \(exited.count) processes")

        self.log?.debug("checking for exit of managed process", metadata: ["exits": "\(exited)", "processes": "\(processes.count)"])
        let exitedProcesses = self.processes.filter { proc in
            exited.contains { pid, _ in
                proc.pid == pid
            }
        }

        for proc in exitedProcesses {
            let pid = proc.pid
            if pid <= 0 {
                continue
            }

            if let status = exited[pid] {
                self.log?.debug(
                    "managed process exited",
                    metadata: [
                        "pid": "\(pid)",
                        "status": "\(status)",
                        "count": "\(processes.count - 1)",
                    ])
                proc.setExit(status)
                self.processes.removeAll(where: { $0.pid == pid })
            }
        }
    }

    func start(process: ManagedProcess) throws -> Int32 {
        self.log?.debug("in supervisor lock to start process")
        defer {
            self.log?.debug("out of supervisor lock to start process")
        }

        do {
            self.processes.append(process)
            return try process.start()
        } catch {
            self.log?.error("process start failed \(error)", metadata: ["process-id": "\(process.id)"])
            throw error
        }
    }

    deinit {
        self.log?.info("process supervisor deinit")
        source.cancel()
    }
}
