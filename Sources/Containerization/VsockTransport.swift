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
/// closed, which invalidates dup'd descriptors. This wrapper captures the
/// connection's close operation and provides explicit, idempotent close semantics.
///
/// Uses `@unchecked Sendable` because the close state is protected by `NSLock`,
/// but the stored close closure may capture a non-Sendable
/// `VZVirtioSocketConnection`.
final class VsockTransport: @unchecked Sendable {
    private let onClose: () -> Void
    private let lock = NSLock()
    private var isClosed = false

    init(_ connection: VZVirtioSocketConnection) {
        self.onClose = { connection.close() }
    }

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    /// Closes the underlying vsock connection, tearing down the host-side endpoint.
    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        onClose()
    }

    deinit {
        close()
    }
}

#endif
