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

import Synchronization

/// Hands out host-side vsock port numbers for guest→host streams, and takes
/// them back when the stream is gone.
///
/// Taking them back is the whole reason this type exists instead of a bare
/// counter. Cloud-hypervisor's hybrid vsock resolves a guest dial to port
/// `P` against the host socket file `<base>_<P>`, freshly per dial, so a
/// port number is only usable if a socket file for exactly that number
/// exists. On hosts where cloud-hypervisor cannot see files created after it
/// forked — apple/container's `--virtualization` mode, see
/// `CHVirtualMachineInstance.stdioPoolSize` — those files have to be bound
/// before the VMM starts, which makes the set of usable numbers finite.
///
/// A monotonically increasing port number turns that finite set into a
/// *lifetime* budget for the VM rather than a concurrency one: at three
/// ports per process, a pool of 16 is spent after five processes even though
/// none of their streams are still open, and every process started after
/// that fails — an `exec` liveness probe every 10s bricks the sandbox in
/// well under a minute. Reusing released numbers makes the pre-bound set
/// bound *concurrent* streams, which is what it was sized for.
///
/// Ports come back when the owning process is deleted rather than when it
/// exits, which is what keeps a straggling dial for a finished stream from
/// reaching a newer process that reused the number. That narrows the window to
/// the moment between a slot's accept loop draining its backlog and the next
/// tenant claiming it, rather than closing it outright — reusing numbers at all
/// means accepting that much.
package final class VsockPortAllocator: Sendable {
    private struct State {
        /// Lowest port never yet handed out.
        var next: UInt32
        /// Ports handed out and given back, available for reuse.
        var free: Set<UInt32>
    }

    private let base: UInt32
    private let state: Mutex<State>

    package init(base: UInt32) {
        self.base = base
        self.state = Mutex(State(next: base, free: []))
    }

    /// Take a port. Prefers the lowest released port, which keeps
    /// allocations packed at the bottom of the range so they stay inside a
    /// pre-bound window for as long as that window covers the concurrent
    /// stream count.
    package func allocate() -> UInt32 {
        state.withLock { state in
            if let reused = state.free.min() {
                state.free.remove(reused)
                return reused
            }
            let port = state.next
            state.next = state.next &+ 1
            return port
        }
    }

    /// Give a port back. Ports this allocator never handed out are ignored,
    /// and releasing the same port twice is a no-op, so callers on
    /// overlapping teardown paths don't have to coordinate.
    package func release(_ port: UInt32) {
        state.withLock { state in
            guard port >= self.base, port < state.next else {
                return
            }
            state.free.insert(port)
        }
    }
}
