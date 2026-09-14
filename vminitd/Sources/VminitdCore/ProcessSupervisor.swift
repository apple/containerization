//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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

#if os(Linux)

import ContainerizationOS
import Foundation
import Logging
import Synchronization

final class ProcessSupervisor: Sendable {
    private let poller: Epoll
    private let handlers = Mutex<[Int32: @Sendable (Epoll.Mask) -> Void]>([:])

    private let queue: DispatchQueue
    // `DispatchSourceSignal` is thread-safe.
    private nonisolated(unsafe) let source: DispatchSourceSignal

    private struct State {
        var processes: [any ContainerProcess] = []
        var log: Logger?

        /// Exits reaped before their owner recorded a pid, oldest first.
        ///
        /// `runc exec --detach` returns once the exec'd process is already
        /// running, so a short-lived exec can be reaped before RuncExecProcess
        /// knows its pid. Most entries are never claimed — every orphan
        /// reparented to vminitd lands here — so eviction bounds this.
        var unclaimedExits: [Int32: ParkedExit] = [:]
        var unclaimedOrder: [Int32] = []
    }

    /// A reaped exit status waiting to be claimed, with the time it was parked.
    private struct ParkedExit {
        let status: Int32
        let parkedAt: ContinuousClock.Instant
    }

    /// How long a parked exit is worth keeping. The park-to-claim window is
    /// microseconds, so anything this old was never going to be claimed.
    ///
    /// Age, not count, is the eviction policy: a count cap alone lets a burst
    /// of unclaimed exits evict a live claimant's entry inside its window,
    /// hanging its `wait()` forever. Expiry is driven by `handleSignal` and
    /// `claimExit` rather than a timer; `claimExit` sweeps before it looks, so
    /// an entry older than this is never handed out.
    private static let maxUnclaimedAge = Duration.seconds(5)

    /// Hard ceiling on parked exits, a memory backstop only. Set well above
    /// what ``maxUnclaimedAge`` can accumulate.
    private static let maxUnclaimedExits = 4096

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
            while true {
                guard let events = self.poller.wait() else {
                    return
                }
                if events.isEmpty {
                    return
                }
                for event in events {
                    let handler = self.handlers.withLock { $0[event.fd] }
                    handler?(event.mask)
                }
            }
        }
        t.start()
    }

    /// Register a file descriptor for epoll monitoring with a handler.
    ///
    /// The handler is stored before the fd is added to epoll, ensuring no
    /// events are missed.
    func registerFd(
        _ fd: Int32,
        mask: Epoll.Mask = [.input, .output],
        handler: @escaping @Sendable (Epoll.Mask) -> Void
    ) throws {
        self.handlers.withLock { $0[fd] = handler }
        do {
            try self.poller.add(fd, mask: mask)
        } catch {
            self.handlers.withLock { _ = $0.removeValue(forKey: fd) }
            throw error
        }
    }

    /// Remove a file descriptor from epoll monitoring and discard its handler.
    func unregisterFd(_ fd: Int32) throws {
        self.handlers.withLock { _ = $0.removeValue(forKey: fd) }
        try self.poller.delete(fd)
    }

    func ready() {
        self.source.setEventHandler {
            self.handleSignal()
        }
        self.source.resume()
    }

    private func handleSignal() {
        dispatchPrecondition(condition: .onQueue(queue))

        // Reaping happens under the state lock so `claimExit` can treat "pid
        // gone and nothing parked" as proof the status was dropped. `wait4` is
        // WNOHANG, so this does not block.
        let exited = self.state.withLock { state -> [Int32: Int32] in
            let exited = Reaper.reap()

            state.log?.debug("received SIGCHLD, reaping processes")
            state.log?.debug("finished wait4 of \(exited.count) processes")
            state.log?.debug("checking for exit of managed process", metadata: ["exits": "\(exited)", "processes": "\(state.processes.count)"])

            // One pass, reading each `pid` exactly once: it is a computed
            // property behind the process's own lock and changes underneath us.
            let work: [(proc: any ContainerProcess, pid: Int32, status: Int32)] = state.processes.compactMap { proc in
                guard let pid = proc.pid, let status = exited[pid] else {
                    return nil
                }
                return (proc, pid, status)
            }

            // Which exits found an owner.
            let matched = Set(work.map { $0.pid })

            for (proc, pid, status) in work {
                state.log?.debug(
                    "managed process exited",
                    metadata: [
                        "pid": "\(pid)",
                        "status": "\(status)",
                        "count": "\(state.processes.count - 1)",
                    ])
                proc.setExit(status)
                // Match on identity, not pid: `setExit` has just moved the
                // process to `.exited`, where both runc implementations report
                // `pid == nil`.
                state.processes.removeAll(where: { $0 === proc })
            }

            // Park whatever matched nothing. Mostly noise -- runc's own
            // short-lived processes and reparented orphans -- but it is also
            // how a fast `runc exec` child's status survives until
            // RuncExecProcess records its pid.
            let now = ContinuousClock.now
            for (pid, status) in exited where !matched.contains(pid) {
                let parked = ParkedExit(status: status, parkedAt: now)
                if state.unclaimedExits.updateValue(parked, forKey: pid) != nil {
                    // Same pid parked twice without a claim: the kernel recycled
                    // it. Drop the stale position to keep the order list a
                    // faithful index of the dictionary.
                    state.unclaimedOrder.removeAll { $0 == pid }
                }
                state.unclaimedOrder.append(pid)
            }

            // `unclaimedOrder` is in park order, oldest first.
            Self.expireUnclaimedExits(&state, now: now)

            while state.unclaimedOrder.count > Self.maxUnclaimedExits {
                let evicted = state.unclaimedOrder.removeFirst()
                state.unclaimedExits.removeValue(forKey: evicted)
                state.log?.debug(
                    "evicted unclaimed exit",
                    metadata: [
                        "pid": "\(evicted)"
                    ])
            }

            return exited
        }

        // Outside the lock: this resumes whoever is awaiting a `runc`
        // invocation, and that task's next move is to call `claimExit`, which
        // needs this lock.
        for (pid, status) in exited {
            reaperCommandRunner.notifyExit(pid: pid, status: status)
        }
    }

    /// Drop parked exits older than ``maxUnclaimedAge``. Called from
    /// `handleSignal` and `claimExit`; there is no timer.
    ///
    /// Must be called with the state lock held.
    private static func expireUnclaimedExits(_ state: inout State, now: ContinuousClock.Instant) {
        while let oldest = state.unclaimedOrder.first {
            guard let parked = state.unclaimedExits[oldest] else {
                // Unreachable: the two containers are only updated together,
                // under this lock. Drop the dangling position rather than stop,
                // which would block expiry of everything behind it.
                state.unclaimedOrder.removeFirst()
                continue
            }
            guard parked.parkedAt.duration(to: now) > Self.maxUnclaimedAge else {
                // In park order, so the first entry young enough ends the sweep.
                return
            }
            state.unclaimedOrder.removeFirst()
            state.unclaimedExits.removeValue(forKey: oldest)
            state.log?.debug(
                "expired unclaimed exit",
                metadata: [
                    "pid": "\(oldest)"
                ])
        }
    }

    /// What `claimExit` found for a pid.
    enum ExitClaim {
        /// A status was parked and is now the caller's to deliver.
        case claimed(Int32)

        /// The pid has been reaped and its status is not anywhere: parked and
        /// then expired, or evicted. Nothing will ever deliver this exit.
        case lost

        /// Nothing to hand over, and nothing lost: either the process is still
        /// running, or its exit has already been delivered through `setExit`.
        case pending
    }

    /// Take the exit status parked for `pid`, if one was reaped before its
    /// owner could register the pid, and say what it means when there isn't one.
    ///
    /// `.claimed` and `.lost` also drop `claimant`'s registration, by identity:
    /// nothing else prunes a claimed process, and the retained reference keeps
    /// `ConsoleSocket.deinit` from reclaiming `/tmp/runc-console-<uuid>`. Doing
    /// it here rather than after the caller's `setExit` also closes the window
    /// in which the claimant is registered with an already-reaped pid.
    ///
    /// Callers must not hold their own process lock: this reads `claimant.pid`,
    /// and `handleSignal` takes this lock and then calls into a process, so
    /// claiming under a process lock would invert that order.
    func claimExit(pid: Int32, claimant: any ContainerProcess) -> ExitClaim {
        self.state.withLock { state in
            // Sweep before looking, or an entry parked while the table was quiet
            // is handed out however old it is -- and old is when it might belong
            // to a recycled pid.
            Self.expireUnclaimedExits(&state, now: .now)

            if let parked = state.unclaimedExits.removeValue(forKey: pid) {
                state.unclaimedOrder.removeAll { $0 == pid }
                state.processes.removeAll { $0 === claimant }
                state.log?.debug(
                    "claimed parked exit",
                    metadata: [
                        "pid": "\(pid)",
                        "status": "\(parked.status)",
                    ])
                return .claimed(parked.status)
            }

            // Nothing parked. A claimant no longer publishing this pid has
            // already been given an exit by `handleSignal`.
            guard claimant.pid == pid else {
                return .pending
            }

            // Otherwise ask the kernel. ESRCH means fully reaped -- a zombie
            // still answers `kill(pid, 0)` -- and reaping happens under this
            // lock, so a reaped pid has already been delivered, parked or
            // expired. The first two are excluded above, so the status is lost.
            let probe = Foundation.kill(pid, 0)
            let probeErrno = errno
            guard probe != 0 && probeErrno == ESRCH else {
                return .pending
            }

            state.processes.removeAll { $0 === claimant }
            state.log?.error(
                "parked exit lost",
                metadata: [
                    "pid": "\(pid)"
                ])
            return .lost
        }
    }

    /// Drop a process's registration without delivering an exit through it.
    ///
    /// Matched by identity, not id: the supervisor is process-wide but an exec
    /// id is only unique within its ManagedContainer, so in a pod two
    /// containers can both own an exec called "shell".
    func deregister(process: any ContainerProcess) {
        self.state.withLock { state in
            state.processes.removeAll { $0 === process }
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
            self.deregister(process: process)
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
        poller.shutdown()
    }
}

#endif
