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

/// A vsock connection whose duplicated file descriptor keeps the originating
/// transport alive until the connection is closed.
///
/// Uses `@unchecked Sendable` because the mutable close state is protected by
/// `NSLock`, while the underlying `FileHandle` and `VsockTransport` are shared
/// across tasks.
public final class VsockConnection: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let transport: VsockTransport
    private let lock = NSLock()
    private var isClosed = false

#if os(macOS)
    init(connection: VZVirtioSocketConnection) throws {
        let fd = dup(connection.fileDescriptor)
        if fd == -1 {
            throw POSIXError.fromErrno()
        }
        self.fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        self.transport = VsockTransport(connection)
    }
#endif

    init(fileDescriptor: Int32, transport: VsockTransport) {
        self.fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        self.transport = transport
    }

    public var fileDescriptor: Int32 {
        fileHandle.fileDescriptor
    }

    public var readabilityHandler: (@Sendable (FileHandle) -> Void)? {
        get { fileHandle.readabilityHandler }
        set { fileHandle.readabilityHandler = newValue }
    }

    public var availableData: Data {
        fileHandle.availableData
    }

    public func write(contentsOf data: some DataProtocol) throws {
        try fileHandle.write(contentsOf: data)
    }

    public func close() throws {
        try closeIfNeeded {
            try fileHandle.close()
        }
    }

    private func closeIfNeeded(_ closeUnderlying: () throws -> Void) throws {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()

        defer { transport.close() }
        try closeUnderlying()
    }

    deinit {
        try? closeIfNeeded {
            try fileHandle.close()
        }
    }
}
