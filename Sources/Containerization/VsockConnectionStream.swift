//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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
public final class VsockConnectionStream: NSObject, Sendable {
    /// A stream of connections dialed from the remote.
    public let connections: AsyncStream<FileHandle>
    /// The port the connections are for.
    public let port: UInt32

    private let cont: AsyncStream<FileHandle>.Continuation

    public init(port: UInt32) {
        self.port = port
        let (stream, continuation) = AsyncStream.makeStream(of: FileHandle.self)
        self.connections = stream
        self.cont = continuation
    }

    public func finish() {
        self.cont.finish()
    }
}

#if os(macOS)

extension VsockConnectionStream: VZVirtioSocketListenerDelegate {
    public func listener(
        _: VZVirtioSocketListener, shouldAcceptNewConnection conn: VZVirtioSocketConnection,
        from _: VZVirtioSocketDevice
    ) -> Bool {
        let fd = dup(conn.fileDescriptor)
        conn.close()

        cont.yield(FileHandle(fileDescriptor: fd, closeOnDealloc: false))
        return true
    }
}

#endif
