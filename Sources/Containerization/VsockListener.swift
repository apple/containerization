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

import Foundation
import Synchronization

#if os(macOS)
import Virtualization
#endif

/// A stream of vsock connections.
public final class VsockListener: NSObject, Sendable, AsyncSequence {
    public typealias Element = FileHandle

    /// The port the connections are for.
    public let port: UInt32

    private let connections: AsyncStream<FileHandle>
    private let cont: AsyncStream<FileHandle>.Continuation
    private let stopListening: @Sendable (_ port: UInt32) throws -> Void
    private let finished: Mutex<Bool>

    package init(port: UInt32, stopListen: @Sendable @escaping (_ port: UInt32) throws -> Void) {
        self.port = port
        let (stream, continuation) = AsyncStream.makeStream(of: FileHandle.self)
        self.connections = stream
        self.cont = continuation
        self.stopListening = stopListen
        self.finished = Mutex(false)
    }

    /// Listener removal is serialized and is not repeated after success.
    /// Failed removal can be retried.
    public func finish() throws {
        try self.finished.withLock { state in
            if state {
                return
            }
            self.cont.finish()
            try self.stopListening(self.port)
            state = true
        }
    }

    /// Push an accepted connection into the listener's stream. Used by
    /// VMM-specific accept loops that don't go through a delegate (the
    /// cloud-hypervisor backend on Linux). On macOS the VZ delegate hits
    /// `cont.yield(_:)` directly via same-class access.
    package func yield(_ handle: FileHandle) -> AsyncStream<FileHandle>.Continuation.YieldResult {
        cont.yield(handle)
    }

    public func makeAsyncIterator() -> AsyncStream<FileHandle>.AsyncIterator {
        connections.makeAsyncIterator()
    }
}

#if os(macOS)

extension VsockListener: VZVirtioSocketListenerDelegate {
    public func listener(
        _: VZVirtioSocketListener, shouldAcceptNewConnection conn: VZVirtioSocketConnection,
        from _: VZVirtioSocketDevice
    ) -> Bool {
        let fd = dup(conn.fileDescriptor)
        guard fd != -1 else {
            return false
        }
        conn.close()

        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let result = cont.yield(fh)
        if case .terminated = result {
            try? fh.close()
            return false
        }

        return true
    }
}

#endif
