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
import ContainerizationError
import Foundation
import Logging
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// One guest→host vsock listening socket, owned by the VM for its entire
/// lifetime and lent out to one `VsockListener` at a time.
///
/// The lifetime is the whole point. Cloud-hypervisor resolves a guest dial to
/// port `P` against the host socket file `<base>_<P>`, freshly on every dial
/// (`virtio-devices/src/vsock/unix/muxer.rs`), and on hosts where it cannot see
/// files created after it forked — apple/container's `--virtualization` mode —
/// that file must exist before the VMM starts. An AF_UNIX socket file whose
/// last fd is closed is permanently dead: a later `connect(2)` gets
/// ECONNREFUSED, and the inode cannot be revived by re-listening. Binding a
/// replacement and renaming it over the path doesn't help either, because that
/// is a new inode created after the fork — exactly what the VMM can't see.
///
/// So a slot that closed its fd when a process finished could never serve
/// another process, which is what turned a pool sized for concurrent streams
/// into a per-VM lifetime budget. Slots instead keep the fd and the path for as
/// long as the VM lives, run a single accept loop, and hand each accepted
/// connection to whichever listener currently owns the slot.
final class CHStdioPortSlot: Sendable {
    let port: UInt32
    let path: URL
    let listenFd: Int32

    private struct State {
        /// The listener entitled to accepted connections right now.
        var owner: VsockListener?
        /// Whether the accept loop is running. Once started it runs until
        /// `shutdown()`, and it owns closing `listenFd`.
        var accepting: Bool
        /// Set by `shutdown()`. Blocks further claims and stops the loop.
        var closed: Bool
    }

    private let state: Mutex<State>

    /// How long the accept loop parks in `poll(2)` before re-checking for
    /// shutdown. This only bounds how long a stopped VM's loop lingers —
    /// connections are still picked up the moment they arrive — so it is far
    /// cheaper than the alternative of a per-slot wakeup pipe: closing an fd
    /// that another thread is parked in `poll(2)` on doesn't reliably wake it
    /// on Linux, so interrupting the loop by hand would mean an extra pair of
    /// fds per slot plus a lock to keep them from being written after reuse.
    private static let pollTimeoutMilliseconds: Int32 = 1000

    init(port: UInt32, path: URL, listenFd: Int32) {
        self.port = port
        self.path = path
        self.listenFd = listenFd
        self.state = Mutex(State(owner: nil, accepting: false, closed: false))
    }

    /// Lend the slot to `listener`.
    ///
    /// Throws if another listener still holds it. That would otherwise
    /// cross-wire two processes' stdio onto one port, so it is a hard error
    /// rather than a wait — the port allocator is responsible for not handing
    /// the same number to two live streams.
    func claim(by listener: VsockListener) throws {
        try state.withLock { state in
            guard !state.closed else {
                throw ContainerizationError(.invalidState, message: "vsock port \(port) is closed")
            }
            guard state.owner == nil else {
                throw ContainerizationError(
                    .invalidState,
                    message: "vsock port \(port) is already being listened on"
                )
            }
            state.owner = listener
        }
    }

    /// Give up ownership without disturbing the socket. The accept loop keeps
    /// running for the next tenant; connections that arrive in between are
    /// dropped by the loop.
    func relinquish() {
        state.withLock { $0.owner = nil }
    }

    /// Start the accept loop, if this is the slot's first tenant. The loop then
    /// runs until `shutdown()`, so ownership handoff never has to stop and
    /// restart it — which is what makes `relinquish()`/`claim(by:)` safe
    /// back-to-back with no settling period.
    func startAcceptingIfNeeded(logger: Logger?) {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.closed, !state.accepting else { return false }
            state.accepting = true
            return true
        }
        guard shouldStart else { return }

        // The loop blocks in poll(2)/accept(2), which is inappropriate for
        // Swift's cooperative thread pool: a pool thread parked in a syscall
        // can't service other tasks until it returns. With even a few of these,
        // detached tasks queue behind the parked threads and never run, which
        // shows up as the guest's dial never being seen by the host.
        // libdispatch's global queue spawns OS threads on demand and is the
        // right tool for a blocking syscall.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            self.acceptLoop(logger: logger)
        }
    }

    /// Stop the accept loop and release the socket. Idempotent, and safe to
    /// call whether or not a loop was ever started.
    func shutdown() {
        // A running loop owns `listenFd` and closes it on its way out; with no
        // loop there is nobody else to do it.
        let closeHere = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.closed = true
            state.owner = nil
            return !state.accepting
        }
        if closeHere {
            _ = close(listenFd)
        }
    }

    private func acceptLoop(logger: Logger?) {
        logger?.debug("vsock acceptLoop starting port=\(port) listenFd=\(listenFd)")
        defer {
            _ = close(listenFd)
            // Mark the slot closed on the way out, not just on the `shutdown()`
            // path. A slot whose loop has stopped can never serve another
            // tenant, and because it stays in the pool the allocator will hand
            // its port out again; without this, every later claim would succeed
            // and then silently wait out its whole dial-back window.
            state.withLock {
                $0.closed = true
                $0.owner = nil
            }
            logger?.debug("vsock acceptLoop exited port=\(port)")
        }

        while !state.withLock({ $0.closed }) {
            var pfd = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
            let rc = withUnsafeMutablePointer(to: &pfd) {
                poll($0, 1, Self.pollTimeoutMilliseconds)
            }
            if rc < 0 {
                let savedErrno = errno
                if savedErrno == EINTR {
                    continue
                }
                logger?.error("vsock acceptLoop poll failed port=\(port) errno=\(savedErrno)")
                return
            }
            if rc == 0 {
                continue
            }
            guard pfd.revents & Int16(POLLIN) != 0 else {
                // POLLERR / POLLNVAL on the listening socket — nothing to
                // recover to.
                logger?.error("vsock acceptLoop listen socket error port=\(port) revents=\(pfd.revents)")
                return
            }

            let connFd = accept(listenFd, nil, nil)
            if connFd < 0 {
                let savedErrno = errno
                if savedErrno == EINTR || savedErrno == EAGAIN || savedErrno == EWOULDBLOCK || savedErrno == ECONNABORTED {
                    continue
                }
                // Host resource pressure is transient, and giving up on it
                // would retire this port for the rest of the VM's life. Back
                // off instead — poll would otherwise report the same pending
                // connection immediately and spin a core.
                if savedErrno == EMFILE || savedErrno == ENFILE || savedErrno == ENOMEM || savedErrno == ENOBUFS {
                    logger?.error("vsock acceptLoop accept deferred port=\(port) errno=\(savedErrno)")
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                logger?.error("vsock acceptLoop accept failed port=\(port) errno=\(savedErrno)")
                return
            }

            let handle = FileHandle(fileDescriptor: connFd, closeOnDealloc: true)
            guard let owner = state.withLock({ $0.owner }) else {
                // A dial for a stream that already gave up the port — e.g. a
                // guest that got to its connect(2) after the host stopped
                // waiting for it. Dropping it here is what keeps it from being
                // delivered to the port's next tenant.
                logger?.warning("vsock dial on port \(port) with no listener; dropping")
                try? handle.close()
                continue
            }
            if case .terminated = owner.yield(handle) {
                try? handle.close()
                // That listener can never take another connection, so free the
                // slot rather than wedging it, and keep accepting.
                relinquish()
            }
        }
    }
}
#endif
