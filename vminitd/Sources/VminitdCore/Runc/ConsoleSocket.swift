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

#if os(Linux)

import ContainerizationError
import ContainerizationOS
import Foundation
import Synchronization

/// A Unix socket for receiving PTY master file descriptors from runc
final class ConsoleSocket: Sendable {
    private let socket: Socket
    private let socketPath: String

    /// A directory this socket created and therefore owns, removed wholesale by
    /// `close()`.
    ///
    /// nil when the caller supplied the path: the parent directory then belongs
    /// to somebody else and must not be removed.
    private let ownedDirectory: String?

    /// Guards `close()` against running twice -- `delete()` then `deinit` is
    /// the normal case. Set as `close()` returns, not on entry, so a failed
    /// step cannot leave half the teardown undone.
    private let isClosed = Mutex(false)

    /// The path to the console socket
    var path: String { socketPath }

    /// Create a new console socket at the specified path
    init(path: String, ownedDirectory: String? = nil) throws {
        let absPath = path.starts(with: "/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        self.socketPath = absPath
        self.ownedDirectory = ownedDirectory

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
    static func temporary() throws -> ConsoleSocket {
        let tmpDir = "/tmp"
        let socketDir = tmpDir + "/runc-console-\(UUID().uuidString)"
        let socketPath = socketDir + "/console.sock"

        try FileManager.default.createDirectory(
            atPath: socketDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // The per-socket directory exists only to hold this socket, so hand it
        // over to be reclaimed on close.
        do {
            return try ConsoleSocket(path: socketPath, ownedDirectory: socketDir)
        } catch {
            // Nothing else can reclaim it: an initializer that threw leaves no
            // ConsoleSocket to close.
            try? FileManager.default.removeItem(atPath: socketDir)
            throw error
        }
    }

    /// Receive the PTY master file descriptor from runc
    func receiveMaster() throws -> Int32 {
        let connection = try socket.accept()
        defer { try? connection.close() }
        return try connection.receiveFileDescriptor()
    }

    /// Close the socket and remove what it created on the filesystem.
    ///
    /// Idempotent: a second call is a no-op. Every step is attempted even if an
    /// earlier one failed, and the first failure is what gets thrown.
    func close() throws {
        try self.isClosed.withLock { isClosed in
            guard !isClosed else {
                return
            }

            // Marked on the way out regardless of whether the steps below
            // succeeded; `deinit` cannot report an error, so a retry there
            // could only fail silently again.
            defer { isClosed = true }

            var firstFailure: (any Error)? = nil

            do {
                try self.socket.close()
            } catch {
                firstFailure = firstFailure ?? error
            }

            // Unlinked here rather than left to the directory removal below: a
            // caller-supplied path has no owned directory. ENOENT is the end
            // state being asked for.
            if unlink(self.socketPath) != 0 {
                let err = errno
                if err != ENOENT {
                    firstFailure =
                        firstFailure
                        ?? ContainerizationError(
                            .internalError,
                            message: "failed to unlink console socket \(self.socketPath): errno \(err)"
                        )
                }
            }

            // Keeps /tmp from collecting one empty runc-console-<uuid> per
            // terminal process.
            if let ownedDirectory = self.ownedDirectory,
                FileManager.default.fileExists(atPath: ownedDirectory)
            {
                do {
                    try FileManager.default.removeItem(atPath: ownedDirectory)
                } catch {
                    firstFailure = firstFailure ?? error
                }
            }

            if let firstFailure {
                throw firstFailure
            }
        }
    }

    deinit {
        try? close()
    }
}

#endif
