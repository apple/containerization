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

#if os(macOS)
import Foundation
import Virtualization

/// Manages the lifecycle of a VZVirtioSocketConnection for use as a gRPC transport.
///
/// When a vsock connection's file descriptor is dup'd and handed to gRPC/NIO,
/// the original VZVirtioSocketConnection must remain open. The Virtualization
/// framework tears down the host-to-guest vsock mapping when the connection is
/// closed, which invalidates dup'd descriptors. This wrapper keeps the
/// connection alive and provides explicit close semantics.
///
/// Uses `@unchecked Sendable` because VZVirtioSocketConnection is not Sendable,
/// which also prevents using Mutex (its init requires a `sending` parameter that
/// conflicts with the non-Sendable connection at async call sites).
final class VsockTransport: @unchecked Sendable {
    private var connection: VZVirtioSocketConnection?
    private let lock = NSLock()

    init(_ connection: VZVirtioSocketConnection) {
        self.connection = connection
    }

    /// Closes the underlying vsock connection, tearing down the host-side endpoint.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        connection?.close()
        connection = nil
    }

    deinit {
        // No lock needed: deinit runs only after all strong references are
        // released, so no concurrent close() call is possible.
        connection?.close()
    }
}

#endif
