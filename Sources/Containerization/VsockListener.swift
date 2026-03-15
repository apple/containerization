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

#if os(macOS)
import Virtualization
#endif

/// A stream of vsock connections.
public final class VsockListener: NSObject, Sendable, AsyncSequence {
    public typealias Element = VsockConnection

    /// The port the connections are for.
    public let port: UInt32

    private let connections: AsyncStream<VsockConnection>
    private let cont: AsyncStream<VsockConnection>.Continuation
    private let stopListening: @Sendable (_ port: UInt32) throws -> Void

    package init(port: UInt32, stopListen: @Sendable @escaping (_ port: UInt32) throws -> Void) {
        self.port = port
        let (stream, continuation) = AsyncStream.makeStream(of: VsockConnection.self)
        self.connections = stream
        self.cont = continuation
        self.stopListening = stopListen
    }

    public func finish() throws {
        self.cont.finish()
        try self.stopListening(self.port)
    }

    public func makeAsyncIterator() -> AsyncStream<VsockConnection>.AsyncIterator {
        connections.makeAsyncIterator()
    }
}

#if os(macOS)

extension VsockListener: VZVirtioSocketListenerDelegate {
    /// Accepts a new vsock connection and yields a retained `VsockConnection`.
    public func listener(
        _: VZVirtioSocketListener, shouldAcceptNewConnection conn: VZVirtioSocketConnection,
        from _: VZVirtioSocketDevice
    ) -> Bool {
        let connection: VsockConnection
        do {
            connection = try conn.retainedConnection()
        } catch {
            return false
        }
        let result = cont.yield(connection)
        if case .terminated = result {
            try? connection.close()
            return false
        }

        return true
    }
}

#endif
