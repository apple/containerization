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

import ContainerizationError
import ContainerizationOS
import Foundation
import NIOCore
import Synchronization

#if os(macOS)
import Virtualization
#endif

/// A stream of vsock connections.
public final class VsockListener: NSObject, Sendable, AsyncSequence {
    public typealias Element = FileHandle

    /// The port the connections are for.
    public let port: UInt32
    package let identity: UUID

    private enum Consumer: Equatable { case publicIterator, owned }
    private struct Pending: Sendable {
        let owner: OwnedDescriptor
        let closeOnDealloc: Bool

        func close() {
            try? owner.close()
        }
    }

    private struct State {
        var pending: CircularBuffer<Pending> = []
        var waiter: CheckedContinuation<Pending?, Never>?
        var consumer: Consumer?
        var requesting = false
        var finished = false
        var released = false
    }

    private let state = Mutex(State())
    private let stopListening: @Sendable (_ port: UInt32) throws -> Void

    package init(port: UInt32, identity: UUID = UUID(), stopListen: @Sendable @escaping (_ port: UInt32) throws -> Void) {
        self.port = port
        self.identity = identity
        self.stopListening = stopListen
    }

    deinit {
        try? cancelAndDiscard()
    }

    /// Stop accepting new connections. Previously queued connections remain drainable.
    /// Idempotent: calling more than once is a no-op. setupIO and the
    /// caller-side defer can both call finish without releasing the
    /// backend listener twice.
    public func finish() throws {
        seal(discard: false)
        try releaseBackend()
    }

    package func cancelAndDiscard() throws {
        seal(discard: true)
        try releaseBackend()
    }

    /// A replaced VZ listener must finish without removing its successor.
    package func replaced() {
        state.withLock { $0.released = true }
        seal(discard: false)
    }

    private func releaseBackend() throws {
        let release = state.withLock {
            guard !$0.released else { return false }
            $0.released = true
            return true
        }
        if release { try stopListening(port) }
    }

    private func seal(discard: Bool) {
        let (discarded, waiter) = state.withLock { state in
            state.finished = true
            let discarded = discard ? state.pending : []
            if discard { state.pending.removeAll() }
            let waiter = state.waiter
            state.waiter = nil
            return (discarded, waiter)
        }
        for entry in discarded { entry.close() }
        waiter?.resume(returning: nil)
    }

    /// Push an accepted connection into the listener's stream. Used by
    /// VMM-specific accept loops that don't go through a delegate (the
    /// cloud-hypervisor backend on Linux), and by the VZ delegate on macOS.
    @discardableResult
    package func yieldOwned(_ descriptor: consuming DescriptorTransfer, closeOnDealloc: Bool = false) -> Bool {
        let entry = Pending(owner: descriptor.takeOwner(), closeOnDealloc: closeOnDealloc)
        let accepted = enqueue(entry)
        if !accepted { entry.close() }
        return accepted
    }

    private func enqueue(_ entry: Pending) -> Bool {
        let result = state.withLock { state -> (Bool, CheckedContinuation<Pending?, Never>?) in
            guard !state.finished else { return (false, nil) }
            if let waiter = state.waiter {
                state.waiter = nil
                return (true, waiter)
            }
            state.pending.append(entry)
            return (true, nil)
        }
        result.1?.resume(returning: entry)
        return result.0
    }

    private func next(for consumer: Consumer) async throws -> Pending? {
        try state.withLock { state in
            if state.consumer == nil { state.consumer = consumer }
            guard state.consumer == consumer, !state.requesting else {
                throw ContainerizationError(.invalidState, message: "vsock listener already has an active consumer")
            }
            state.requesting = true
        }
        defer { state.withLock { $0.requesting = false } }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result = state.withLock { state -> Pending?? in
                    if !state.pending.isEmpty { return .some(state.pending.removeFirst()) }
                    if state.finished { return .some(nil) }
                    state.waiter = continuation
                    return nil
                }
                if let result { continuation.resume(returning: result) }
            }
        } onCancel: {
            try? self.cancelAndDiscard()
        }
    }

    package func nextOwned() async throws -> DescriptorTransfer? {
        guard let next = try await next(for: .owned) else { return nil }
        return DescriptorTransfer(owner: next.owner)
    }

    /// Iterators share one connection stream, and only one may wait at a time. An iterator
    /// that calls `next()` while another waits ends without an error. Cancelling a pending
    /// `next()` removes the backend listener and discards queued connections.
    public func makeAsyncIterator() -> AsyncStream<FileHandle>.AsyncIterator {
        let admitted = state.withLock { state in
            guard state.consumer == nil || state.consumer == .publicIterator else { return false }
            state.consumer = .publicIterator
            return true
        }
        guard admitted else { return AsyncStream<FileHandle> { $0.finish() }.makeAsyncIterator() }
        // A consumer cancelled between elements never re-enters next(for:), whose own
        // handler would otherwise discard queued connections and release the backend.
        return AsyncStream<FileHandle>(
            unfolding: { [self] in
                while let entry = try? await next(for: .publicIterator) {
                    if let handle = try? exportVsockHandle(DescriptorTransfer(owner: entry.owner), closeOnDealloc: entry.closeOnDealloc) {
                        return handle
                    }
                }
                return nil
            },
            onCancel: { [self] in try? cancelAndDiscard() }
        ).makeAsyncIterator()
    }
}

#if os(macOS)
extension VsockListener: VZVirtioSocketListenerDelegate {
    public func listener(
        _: VZVirtioSocketListener, shouldAcceptNewConnection conn: VZVirtioSocketConnection,
        from _: VZVirtioSocketDevice
    ) -> Bool {
        do {
            return yieldOwned(try conn.dupOwned())
        } catch {
            return false
        }
    }
}
#endif
