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

import ContainerizationOS
import Foundation
import Logging
import Synchronization

final class ProcessSupervisor: Sendable {
    let poller: Epoll

    private let queue: DispatchQueue
    // `DispatchSourceSignal` is thread-safe.
    private nonisolated(unsafe) let source: DispatchSourceSignal

    private struct State {
        var processes: [any ContainerProcess] = []
        var log: Logger?
    }

    private let state: Mutex<State>
    private let reaperCommandRunner = ReaperCommandRunner()

    func setLog(_ log: Logger?) {
        self.state.withLock { $0.log = log }
    }

    static let `default` = ProcessSupervisor()

    private init() {
        let queue = DispatchQueue(label: "process-supervisor")
        self.source = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
        self.queue = queue
        self.poller = try! Epoll()
        self.state = Mutex(State())
        let t = Thread {
            try! self.poller.run()
        }
        t.start()
    }

    func ready() {
        self.source.setEventHandler {
            self.handleSignal()
        }
        self.source.resume()
    }

    private func handleSignal() {
        dispatchPrecondition(condition: .onQueue(queue))

        let exited = Reaper.reap()

        for (pid, status) in exited {
            reaperCommandRunner.notifyExit(pid: pid, status: status)
        }

        self.state.withLock { state in
            state.log?.debug("received SIGCHLD, reaping processes")
            state.log?.debug("finished wait4 of \(exited.count) processes")
            state.log?.debug("checking for exit of managed process", metadata: ["exits": "\(exited)", "processes": "\(state.processes.count)"])

            let exitedProcesses = state.processes.filter { proc in
                exited.contains { pid, _ in
                    proc.pid == pid
                }
            }

            for proc in exitedProcesses {
                guard let pid = proc.pid else {
                    continue
                }

                if let status = exited[pid] {
                    state.log?.debug(
                        "managed process exited",
                        metadata: [
                            "pid": "\(pid)",
                            "status": "\(status)",
                            "count": "\(state.processes.count - 1)",
                        ])
                    proc.setExit(status)
                    state.processes.removeAll(where: { $0.pid == pid })
                }
            }
        }
    }

    func start(process: any ContainerProcess) async throws -> Int32 {
        self.state.withLock { state in
            state.log?.debug("in supervisor lock to start process")
            state.processes.append(process)
        }
        do {
            return try await process.start()
        } catch {
            self.state.withLock { state in
                state.processes.removeAll(where: { $0.id == process.id })
            }
            throw error
        }
    }

    /// Get a Runc instance configured with the reaper command runner
    func getRuncWithReaper(_ base: Runc = Runc()) -> Runc {
        var runc = base
        runc.commandRunner = reaperCommandRunner
        return runc
    }

    deinit {
        source.cancel()
        try? poller.shutdown()
    }
}
