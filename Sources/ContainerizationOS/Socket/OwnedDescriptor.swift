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

import Foundation
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Pins one descriptor across uses. Its holder must explicitly initiate closure.
package final class OwnedDescriptor: Sendable {
    private enum Phase { case open, closing, finalizing, closed, released }
    private struct State {
        var phase = Phase.open
        var uses = 0
        var nextID: UInt64 = 0
        var cancellations: [UInt64: @Sendable () -> Void] = [:]
        var wake: (read: Int32, write: Int32)?
        var closePayload = true
        var result: Result<Void, SocketError>?
        var completions: [CheckedContinuation<Void, any Error>] = []
    }

    private let descriptor: Int32
    private let closeImplementation: @Sendable (Int32) -> Int32
    private let state = Mutex(State())

    package convenience init(adopting descriptor: Int32) {
        self.init(adopting: descriptor, closeImplementation: { sysClose($0) })
    }

    init(adopting descriptor: Int32, closeImplementation: @escaping @Sendable (Int32) -> Int32) {
        precondition(descriptor >= 0)
        self.descriptor = descriptor
        self.closeImplementation = closeImplementation
    }

    // Payload cleanup belongs to the holder; closeOnDeinit:false must remain valid.
    deinit {
        let (phase, wake) = state.withLock { ($0.phase, $0.wake) }
        assert(phase == .closed || phase == .released, "OwnedDescriptor dropped without close or release; its descriptor leaks")
        Self.close(wake)
    }

    private static func close(_ wake: (read: Int32, write: Int32)?) {
        guard let wake else { return }
        _ = sysClose(wake.read)
        _ = sysClose(wake.write)
    }

    package final class Use: Sendable {
        package let fileDescriptor: Int32
        private let reference: Mutex<(owner: OwnedDescriptor, id: UInt64)?>

        fileprivate init(owner: OwnedDescriptor, id: UInt64) {
            self.fileDescriptor = owner.descriptor
            self.reference = Mutex((owner, id))
        }

        /// Idempotent. Registrations end only after cancellation/unregister acknowledgement.
        package func end() {
            let reference = reference.withLock { value in
                let previous = value
                value = nil
                return previous
            }
            if let reference { reference.owner.endUse(id: reference.id) }
        }

        deinit { end() }
    }

    package func acquire(onClose: (@Sendable () -> Void)? = nil) throws -> Use {
        try state.withLock { state in
            guard state.phase == .open else { throw SocketError.closed }
            state.uses += 1
            state.nextID &+= 1
            if let onClose { state.cancellations[state.nextID] = onClose }
            return Use(owner: self, id: state.nextID)
        }
    }

    package func checkOpen() throws {
        try state.withLock { state in
            guard state.phase == .open else { throw SocketError.closed }
        }
    }

    package var fileDescriptor: Int32 {
        state.withLock { $0.phase == .open ? descriptor : -1 }
    }

    package var isIdle: Bool {
        state.withLock { $0.phase == .open && $0.uses == 0 }
    }

    /// Transition under Socket's gate; execute the returned cleanup outside it.
    func beginClose(closePayload: Bool = true) -> @Sendable () throws -> Void {
        let work = state.withLock { state -> (started: Bool, wake: Int32?, cancellations: [@Sendable () -> Void]) in
            guard state.phase == .open else { return (false, nil, []) }
            state.phase = .closing
            state.closePayload = closePayload
            state.uses += 1  // Protect the wake pipe while signalling outside the lock.
            let callbacks = Array(state.cancellations.values)
            state.cancellations.removeAll()
            return (true, state.wake?.write, callbacks)
        }
        return { [self] in
            if work.started {
                if let fd = work.wake {
                    var byte: UInt8 = 1
                    while write(fd, &byte, 1) < 0 && errno == EINTR {}
                }
                for cancel in work.cancellations { cancel() }
                endUse(id: nil)
            }
            if let result = state.withLock({ $0.result }) { try result.get() }
        }
    }

    package func close() throws { try beginClose()() }

    package func closeAndWait() async throws {
        try close()
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLock { state -> Result<Void, SocketError>? in
                if let result = state.result { return result }
                state.completions.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
        }
    }

    /// Closes the private wake pipe of an idle descriptor. Transfer receivers do not
    /// wait through it, and a later managed wait creates a new one.
    fileprivate func discardWakePipe() {
        Self.close(
            state.withLock { state -> (read: Int32, write: Int32)? in
                guard state.phase == .open && state.uses == 0 else { return nil }
                defer { state.wake = nil }
                return state.wake
            })
    }

    /// Relinquish an idle descriptor; the caller becomes responsible for closing it.
    package func release() throws -> Int32 {
        let wake = try state.withLock { state in
            guard state.phase == .open && state.uses == 0 else {
                throw SocketError.invalidOperationOnSocket("release active descriptor")
            }
            state.phase = .released
            state.result = .failure(.invalidOperationOnSocket("released descriptor"))
            let wake = state.wake
            state.wake = nil
            return wake
        }
        Self.close(wake)
        return descriptor
    }

    private func endUse(id: UInt64?) {
        let finalization = state.withLock { state -> (closePayload: Bool, wake: (read: Int32, write: Int32)?)? in
            if let id { state.cancellations.removeValue(forKey: id) }
            state.uses -= 1
            precondition(state.uses >= 0)
            guard state.phase == .closing && state.uses == 0 else { return nil }
            state.phase = .finalizing
            let wake = state.wake
            state.wake = nil
            return (state.closePayload, wake)
        }
        guard let finalization else { return }
        let result: Result<Void, SocketError>
        // close(2) is never retried: the descriptor number may already be reused.
        if finalization.closePayload && closeImplementation(descriptor) < 0 {
            let error = errno
            result = .failure(.withErrno("close failed", errno: error))
        } else {
            result = .success(())
        }
        Self.close(finalization.wake)
        let completions = state.withLock { state in
            state.phase = .closed
            state.result = result
            let completions = state.completions
            state.completions.removeAll()
            return completions
        }
        for completion in completions { completion.resume(with: result.mapError { $0 as any Error }) }
    }

    /// Requires an active Use.
    func wakeDescriptor() throws -> Int32 {
        if let fd = try state.withLock({ state -> Int32? in
            guard state.phase == .open else { throw SocketError.closed }
            return state.wake?.read
        }) {
            return fd
        }

        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Socket.errnoToError(msg: "create socket wake pipe") }
        var installed = false
        defer {
            if !installed {
                _ = sysClose(descriptors[0])
                _ = sysClose(descriptors[1])
            }
        }
        for fd in descriptors {
            try Socket.setDescriptorFlags(fd)
        }
        return try state.withLock { state in
            guard state.phase == .open else { throw SocketError.closed }
            if let existing = state.wake { return existing.read }
            state.wake = (descriptors[0], descriptors[1])
            installed = true
            return descriptors[0]
        }
    }
}

/// Transfers cleanup responsibility; closes if abandoned.
package struct DescriptorTransfer: ~Copyable, Sendable {
    private var owner: OwnedDescriptor?

    package init(adopting descriptor: Int32) { self.owner = OwnedDescriptor(adopting: descriptor) }
    package init(owner: OwnedDescriptor) {
        assert(owner.isIdle, "only an open, idle descriptor can be transferred")
        owner.discardWakePipe()
        self.owner = owner
    }

    package consuming func takeOwner() -> OwnedDescriptor {
        guard let owner else { preconditionFailure("descriptor transfer already consumed") }
        self.owner = nil
        return owner
    }

    package consuming func release() throws -> Int32 {
        guard let owner else { preconditionFailure("descriptor transfer already consumed") }
        let fd = try owner.release()
        self.owner = nil
        return fd
    }

    deinit { try? owner?.close() }
}
