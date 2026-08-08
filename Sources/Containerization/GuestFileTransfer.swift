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

import ContainerizationArchive
import ContainerizationError
import ContainerizationOS
import Foundation

/// Moves files between the host and a container's filesystem inside a guest.
///
/// The transfer runs over a dedicated vsock connection on a port the caller
/// allocates. A container in a machine of its own and a container among
/// several in a pod differ only in where their filesystem sits in the guest,
/// so that path is what this is given.
struct GuestFileTransfer: Sendable {
    /// Default chunk size for file transfers (1MiB).
    static let defaultChunkSize = 1024 * 1024

    /// The machine holding the container's filesystem.
    let vm: any VirtualMachineInstance
    /// Where the container's filesystem sits in the guest.
    let guestRoot: String
    /// The vsock port the data travels over.
    let port: UInt32
    /// Where the blocking read and write work runs.
    let queue: DispatchQueue

    /// Copy a file or directory from the host into the container.
    ///
    /// For directories, the source is archived as tar+gzip and streamed
    /// directly through vsock without intermediate temp files.
    func copyIn(
        from source: URL,
        to destination: URL,
        mode: UInt32,
        createParents: Bool,
        chunkSize: Int
    ) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ContainerizationError(.notFound, message: "copyIn: source not found '\(source.path)'")
        }
        let isArchive = isDirectory.boolValue

        let guestPath: URL = try await vm.withAgent { agent in
            guard let vminitd = agent as? Vminitd else {
                throw ContainerizationError(.unsupported, message: "copyIn requires Vminitd agent")
            }

            return try await self.resolveCopyInGuestPath(
                from: source,
                to: destination,
                sourceIsDirectory: isArchive,
                using: vminitd
            )
        }

        let listener = try vm.listen(port)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.vm.withAgent { agent in
                    guard let vminitd = agent as? Vminitd else {
                        throw ContainerizationError(.unsupported, message: "copyIn requires Vminitd agent")
                    }
                    try await vminitd.copy(
                        direction: .copyIn,
                        guestPath: guestPath,
                        vsockPort: self.port,
                        mode: mode,
                        createParents: createParents,
                        isArchive: isArchive
                    )
                }
            }

            group.addTask {
                guard let conn = await listener.first(where: { _ in true }) else {
                    throw ContainerizationError(.internalError, message: "copyIn: vsock connection not established")
                }
                try listener.finish()

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    self.queue.async {
                        do {
                            defer { conn.closeFile() }

                            if isArchive {
                                let writer = try ArchiveWriter(configuration: .init(format: .pax, filter: .gzip))
                                try writer.open(fileDescriptor: conn.fileDescriptor)
                                try writer.archiveDirectory(source)
                                try writer.finishEncoding()
                            } else {
                                let srcFd = open(source.path, O_RDONLY)
                                guard srcFd != -1 else {
                                    throw ContainerizationError(
                                        .internalError,
                                        message: "copyIn: failed to open '\(source.path)': \(String(cString: strerror(errno)))"
                                    )
                                }
                                defer { close(srcFd) }

                                var buf = [UInt8](repeating: 0, count: chunkSize)
                                while true {
                                    let n = read(srcFd, &buf, buf.count)
                                    if n == 0 { break }
                                    guard n > 0 else {
                                        throw ContainerizationError(
                                            .internalError,
                                            message: "copyIn: read error: \(String(cString: strerror(errno)))"
                                        )
                                    }
                                    var written = 0
                                    while written < n {
                                        let w = buf.withUnsafeBytes { ptr in
                                            write(conn.fileDescriptor, ptr.baseAddress! + written, n - written)
                                        }
                                        guard w > 0 else {
                                            throw ContainerizationError(
                                                .internalError,
                                                message: "copyIn: vsock write error: \(String(cString: strerror(errno)))"
                                            )
                                        }
                                        written += w
                                    }
                                }
                            }
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    /// Copy a file or directory from the container to the host.
    ///
    /// For directories, the guest archives the source as tar+gzip and streams
    /// it directly through vsock. The host extracts the archive without
    /// intermediate temp files.
    func copyOut(
        from source: URL,
        to destination: URL,
        createParents: Bool,
        chunkSize: Int
    ) async throws {
        if createParents {
            let parentDir = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let guestPath = URL(filePath: guestRoot).appending(path: source.path)
        let listener = try vm.listen(port)

        let (metadataStream, metadataCont) = AsyncStream.makeStream(of: Vminitd.CopyMetadata.self)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { metadataCont.finish() }
                try await self.vm.withAgent { agent in
                    guard let vminitd = agent as? Vminitd else {
                        throw ContainerizationError(.unsupported, message: "copyOut requires Vminitd agent")
                    }
                    try await vminitd.copy(
                        direction: .copyOut,
                        guestPath: guestPath,
                        vsockPort: self.port,
                        onMetadata: { meta in
                            metadataCont.yield(meta)
                            metadataCont.finish()
                        }
                    )
                }
            }

            group.addTask {
                guard let metadata = await metadataStream.first(where: { _ in true }) else {
                    throw ContainerizationError(.internalError, message: "copyOut: no metadata received")
                }

                guard let conn = await listener.first(where: { _ in true }) else {
                    throw ContainerizationError(.internalError, message: "copyOut: vsock connection not established")
                }
                try listener.finish()

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    self.queue.async {
                        do {
                            defer { conn.closeFile() }

                            if metadata.isArchive {
                                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                                let fh = FileHandle(fileDescriptor: dup(conn.fileDescriptor), closeOnDealloc: true)
                                let reader = try ArchiveReader(format: .pax, filter: .gzip, fileHandle: fh)
                                _ = try reader.extractContents(to: destination)
                            } else {
                                let destFd = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                                guard destFd != -1 else {
                                    throw ContainerizationError(
                                        .internalError,
                                        message: "copyOut: failed to open '\(destination.path)': \(String(cString: strerror(errno)))"
                                    )
                                }
                                defer { close(destFd) }

                                var buf = [UInt8](repeating: 0, count: chunkSize)
                                while true {
                                    let n = read(conn.fileDescriptor, &buf, buf.count)
                                    if n == 0 { break }
                                    guard n > 0 else {
                                        throw ContainerizationError(
                                            .internalError,
                                            message: "copyOut: vsock read error: \(String(cString: strerror(errno)))"
                                        )
                                    }
                                    var written = 0
                                    while written < n {
                                        let w = buf.withUnsafeBytes { ptr in
                                            write(destFd, ptr.baseAddress! + written, n - written)
                                        }
                                        guard w > 0 else {
                                            throw ContainerizationError(
                                                .internalError,
                                                message: "copyOut: write error: \(String(cString: strerror(errno)))"
                                            )
                                        }
                                        written += w
                                    }
                                }
                            }
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    /// Where a copy lands in the guest, given what the destination already is.
    ///
    /// A destination that names an existing directory receives the source
    /// under its own name, the way `cp` behaves.
    private func resolveCopyInGuestPath(
        from source: URL,
        to destination: URL,
        sourceIsDirectory: Bool,
        using vminitd: Vminitd
    ) async throws -> URL {
        let guestDestination = URL(filePath: guestRoot).appending(path: destination.path)

        let stat: ContainerizationOS.Stat?
        do {
            stat = try await vminitd.stat(path: guestDestination)
        } catch let error as ContainerizationError where error.code == .notFound {
            stat = nil
        }
        // Any other error propagates so transport and permission failures are visible.

        guard let stat else {
            if destination.hasDirectoryPath && !sourceIsDirectory {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "destination directory does not exist: \(destination.path)"
                )
            }
            return guestDestination
        }

        let destinationIsDirectory = (stat.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
        guard destinationIsDirectory else {
            if sourceIsDirectory {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "cannot copy directory over existing file: \(destination.path)"
                )
            }
            return guestDestination
        }

        return guestDestination.appendingPathComponent(source.lastPathComponent)
    }
}
