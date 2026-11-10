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
import CShim
import ContainerizationError
import ContainerizationOS
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
    private let descriptor: OwnedDescriptor

    private struct State {
        /// The listener entitled to accepted connections right now.
        weak var owner: VsockListener?
        var claim: UUID?
        /// Whether the accept loop is running. Once started it runs until
        /// `shutdown()`, holding a descriptor use until it exits.
        var accepting: Bool
        /// Set by `shutdown()` or a failed accept loop. Blocks further claims
        /// and stops the loop.
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

    init(port: UInt32, path: URL, listenDescriptor: consuming DescriptorTransfer) {
        self.port = port
        self.path = path
        self.descriptor = listenDescriptor.takeOwner()
        self.listenFd = descriptor.fileDescriptor
        self.state = Mutex(State(owner: nil, claim: nil, accepting: false, closed: false))
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
            // Loading the weak owner here can run its deinit under this mutex,
            // reentering relinquish when the temporary strong reference drops.
            guard state.claim == nil else {
                throw ContainerizationError(
                    .invalidState,
                    message: "vsock port \(port) is already being listened on"
                )
            }
            state.owner = listener
            state.claim = listener.identity
        }
    }

    /// Give up the matching claim without disturbing the socket. The accept
    /// loop keeps running for the next tenant; connections that arrive in between are
    /// dropped by the loop.
    func relinquish(_ identity: UUID) {
        state.withLock {
            guard $0.claim == identity else { return }
            $0.owner = nil
            $0.claim = nil
        }
    }

    deinit {
        try? descriptor.close()
    }

    /// Start the accept loop, if this is the slot's first tenant. The loop then
    /// runs until `shutdown()`, so ownership handoff never has to stop and
    /// restart it — which is what makes `relinquish(_:)`/`claim(by:)` safe
    /// back-to-back with no settling period.
    func startAcceptingIfNeeded(logger: Logger?) {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.closed, !state.accepting else { return false }
            state.accepting = true
            return true
        }
        guard shouldStart else { return }

        // The loop blocks in poll(2), which is inappropriate for
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
    /// The descriptor closes after the loop releases its active use.
    func shutdown() {
        // A running loop keeps `listenFd` alive through its descriptor use;
        // with no active loop, closing the descriptor releases it immediately.
        let listener = state.withLock { state -> VsockListener? in
            guard !state.closed else { return nil }
            state.closed = true
            let listener = state.owner
            state.owner = nil
            state.claim = nil
            return listener
        }
        try? listener?.cancelAndDiscard()
        try? descriptor.close()
    }

    private func acceptLoop(logger: Logger?) {
        logger?.debug("vsock acceptLoop starting port=\(port) listenFd=\(listenFd)")
        guard let use = try? descriptor.acquire() else { return }
        defer {
            use.end()
            try? descriptor.close()
            // Mark the slot closed on the way out, not just on the `shutdown()`
            // path. A slot whose loop has stopped can never serve another
            // tenant, and because it stays in the pool the allocator will hand
            // its port out again; without this, every later claim would succeed
            // and then silently wait out its whole dial-back window.
            let listener = state.withLock {
                $0.closed = true
                let listener = $0.owner
                $0.owner = nil
                $0.claim = nil
                return listener
            }
            try? listener?.cancelAndDiscard()
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

            // Accept is nonblocking. Pair it with the current claim so a handover
            // before delivery cannot send this connection to the next listener.
            let accepted = state.withLock { state -> (fd: Int32, error: Int32, owner: VsockListener?)? in
                guard !state.closed else { return nil }
                let owner = state.owner
                let fd = CZ_accept_cloexec(listenFd)
                return (fd, errno, owner)
            }
            guard let accepted else { return }
            let connFd = accepted.fd
            if connFd < 0 {
                let savedErrno = accepted.error
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

            let connection = DescriptorTransfer(adopting: connFd)
            guard let owner = accepted.owner else {
                // A dial for a stream that already gave up the port — e.g. a
                // guest that got to its connect(2) after the host stopped
                // waiting for it. Dropping it here is what keeps it from being
                // delivered to the port's next tenant.
                logger?.warning("vsock dial on port \(port) with no listener; dropping")
                continue
            }
            if !owner.yieldOwned(connection, closeOnDealloc: true) {
                // That listener can never take another connection, so free the
                // slot rather than wedging it, and keep accepting.
                relinquish(owner.identity)
            }
        }
    }
}
#endif
