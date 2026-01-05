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

import ContainerizationOS
import Foundation

#if os(Linux)

/// A Unix socket for receiving PTY master file descriptors from runc
public final class ConsoleSocket: Sendable {
    private let socket: Socket
    private let socketPath: String

    /// The path to the console socket
    public var path: String { socketPath }

    /// Create a new console socket at the specified path
    public init(path: String) throws {
        let absPath = path.starts(with: "/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        self.socketPath = absPath

        let pathURL = URL(fileURLWithPath: absPath)
        let dir = pathURL.deletingLastPathComponent().path
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let socketType = try UnixType(path: absPath, unlinkExisting: true)
        self.socket = try Socket(type: socketType)

        try socket.listen()
    }

    /// Create a temporary console socket in the runtime directory
    public static func temporary() throws -> ConsoleSocket {
        let tmpDir = "/tmp"
        let socketDir = tmpDir + "/runc-console-\(UUID().uuidString)"
        let socketPath = socketDir + "/console.sock"

        try FileManager.default.createDirectory(
            atPath: socketDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let socket = try ConsoleSocket(path: socketPath)
        return socket
    }

    /// Receive the PTY master file descriptor from runc
    public func receiveMaster() throws -> Int32 {
        let connection = try socket.accept()
        defer { try? connection.close() }
        return try connection.receiveFileDescriptor()
    }

    /// Close the socket and optionally remove the socket file
    public func close() throws {
        try socket.close()
        try FileManager.default.removeItem(atPath: socketPath)
    }

    deinit {
        try? close()
    }
}

#endif  // os(Linux)
