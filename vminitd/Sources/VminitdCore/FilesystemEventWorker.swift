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

import Containerization
import ContainerizationError
import Foundation
import Logging
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - FilesystemEventWorker

/// Triggers synthetic inotify events inside a container's mount namespace.
///
/// Architecture: a dedicated thread enters the container's mount namespace via setns(),
/// then blocks on a signal pipe. The parent enqueues events into a Mutex-protected queue
/// and writes a wake byte. The worker drains the queue and "pokes" each file via no-op
/// chmod to trigger inotify.
final class FilesystemEventWorker: Sendable {

    // MARK: - Types

    struct FSEvent: Sendable {
        let path: String
        let eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType
    }

    enum Phase: Sendable {
        case created, starting, running, stopping, stopped
    }

    struct State: Sendable {
        var phase: Phase = .created
        var queue: [FSEvent] = []
        var signalPipeRead: CInt = -1
        var signalPipeWrite: CInt = -1
        var statusPipeRead: CInt = -1
        var statusPipeWrite: CInt = -1
        var startError: (any Error)?
    }

    // MARK: Properties

    let containerID: String
    private let log: Logger
    private let state: Mutex<State>

    private static let handshakeReady: UInt8 = 0xAA
    private static let handshakeFailure: UInt8 = 0xFF
    private static let doneByte: UInt8 = 0xFE

    // MARK: Init

    init(containerID: String, log: Logger) {
        self.containerID = containerID
        self.log = log
        self.state = Mutex(State())
    }

    // MARK: - Lifecycle

    /// Start the worker thread. Blocks briefly for the namespace-entry handshake.
    func start(containerPID: Int32) throws {
        try state.withLock { s in
            guard s.phase == .created else {
                throw ContainerizationError(.internalError, message: "fsnotify: worker already started")
            }
        }

        let signalPipe = try makePipe(nonblockWrite: true)
        let statusPipe: (read: CInt, write: CInt)
        do {
            statusPipe = try makePipe()
        } catch {
            close(signalPipe.read)
            close(signalPipe.write)
            throw error
        }

        state.withLock { s in
            s.signalPipeRead = signalPipe.read
            s.signalPipeWrite = signalPipe.write
            s.statusPipeRead = statusPipe.read
            s.statusPipeWrite = statusPipe.write
            s.phase = .starting
        }

        let thread = Thread { [weak self] in
            self?.workerMain(
                signalPipeRead: signalPipe.read,
                statusPipeWrite: statusPipe.write,
                containerPID: containerPID
            )
        }
        thread.name = "fsnotify-\(containerID)"
        thread.start()

        // Block for handshake — completes in microseconds (just setns + write)
        var handshake: UInt8 = 0
        let n = read(statusPipe.read, &handshake, 1)

        if n <= 0 || handshake == Self.handshakeFailure {
            let error = state.withLock { $0.startError }
            // statusPipeWrite already closed by worker on failure
            close(signalPipe.read)
            close(signalPipe.write)
            close(statusPipe.read)
            state.withLock { s in
                s.signalPipeRead = -1
                s.signalPipeWrite = -1
                s.statusPipeRead = -1
                s.statusPipeWrite = -1
                s.phase = .stopped
            }
            throw error
                ?? ContainerizationError(
                    .internalError, message: "fsnotify: worker failed to start")
        }

        state.withLock { $0.phase = .running }
        log.info("fsnotify worker started", metadata: ["containerID": "\(containerID)"])
    }

    /// Enqueue a filesystem event for the worker to process.
    func enqueueEvent(path: String, eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType) throws {
        // The pipe write is inside the lock to prevent stop() from closing the FD
        // between the phase check and the write. O_NONBLOCK ensures this never blocks.
        try state.withLock { s in
            guard s.phase == .running else {
                throw ContainerizationError(.internalError, message: "fsnotify worker not running")
            }
            s.queue.append(FSEvent(path: path, eventType: eventType))
            var byte: UInt8 = 0x01
            if write(s.signalPipeWrite, &byte, 1) < 0 && errno != EAGAIN {
                log.warning("fsnotify: failed to write wake byte", metadata: ["errno": "\(errno)"])
            }
        }
    }

    /// Stop the worker and wait for it to exit. Async to avoid blocking the cooperative thread pool.
    func stop() async {
        let (writeEnd, readEnd) = state.withLock { s -> (CInt, CInt) in
            guard s.phase == .running else { return (-1, -1) }
            s.phase = .stopping
            return (s.signalPipeWrite, s.statusPipeRead)
        }
        guard writeEnd != -1 else { return }

        var byte: UInt8 = 0x01
        _ = write(writeEnd, &byte, 1)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                var doneByte: UInt8 = 0
                _ = read(readEnd, &doneByte, 1)
                continuation.resume()
            }
        }

        state.withLock { s in
            close(s.signalPipeRead)
            close(s.signalPipeWrite)
            close(s.statusPipeRead)
            s.signalPipeRead = -1
            s.signalPipeWrite = -1
            s.statusPipeRead = -1
            s.statusPipeWrite = -1
            s.phase = .stopped
        }
        log.info("fsnotify worker stopped", metadata: ["containerID": "\(containerID)"])
    }

    // MARK: - Worker Thread

    private func workerMain(signalPipeRead: CInt, statusPipeWrite: CInt, containerPID: Int32) {
        do {
            try enterContainerNamespace(pid: containerPID)
        } catch {
            state.withLock { $0.startError = error }
            var byte = Self.handshakeFailure
            _ = write(statusPipeWrite, &byte, 1)
            close(statusPipeWrite)
            return
        }

        var readyByte = Self.handshakeReady
        _ = write(statusPipeWrite, &readyByte, 1)

        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let n = buf.withUnsafeMutableBytes { ptr in
                read(signalPipeRead, ptr.baseAddress!, ptr.count)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }

            let (events, shouldStop) = state.withLock { s -> ([FSEvent], Bool) in
                let events = s.queue
                s.queue.removeAll(keepingCapacity: true)
                return (events, s.phase == .stopping)
            }

            for event in events {
                pokeFile(event.path)
            }

            if shouldStop { break }
        }

        var done = Self.doneByte
        _ = write(statusPipeWrite, &done, 1)
        close(statusPipeWrite)
    }

    // MARK: - File Poking

    /// Trigger a synthetic inotify event via no-op chmod (same permissions) which triggers IN_ATTRIB.
    private func pokeFile(_ path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else {
            log.debug("fsnotify: stat failed, skipping", metadata: ["path": "\(path)", "errno": "\(errno)"])
            return
        }

        guard chmod(path, st.st_mode & 0o7777) == 0 else {
            log.warning("fsnotify: chmod failed", metadata: ["path": "\(path)", "errno": "\(errno)"])
            return
        }
    }

    // MARK: - Namespace Entry

    private func enterContainerNamespace(pid: Int32) throws {
        let nsPath = "/proc/\(pid)/ns/mnt"
        let selfNsPath = "/proc/self/ns/mnt"

        var nsStat = stat()
        var selfStat = stat()

        guard stat(nsPath, &nsStat) == 0 else {
            throw ContainerizationError(.internalError, message: "fsnotify: failed to stat \(nsPath): errno \(errno)")
        }
        guard stat(selfNsPath, &selfStat) == 0 else {
            throw ContainerizationError(.internalError, message: "fsnotify: failed to stat \(selfNsPath): errno \(errno)")
        }

        if nsStat.st_ino == selfStat.st_ino { return }

        let fd = open(nsPath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw ContainerizationError(.internalError, message: "fsnotify: failed to open \(nsPath): errno \(errno)")
        }
        defer { close(fd) }

        guard unshare(CInt(CLONE_FS)) == 0 else {
            throw ContainerizationError(.internalError, message: "fsnotify: unshare(CLONE_FS) failed: errno \(errno)")
        }
        guard setns(fd, CInt(CLONE_NEWNS)) == 0 else {
            throw ContainerizationError(.internalError, message: "fsnotify: setns failed: errno \(errno)")
        }
    }

    // MARK: - Helpers

    /// Create a pipe with O_CLOEXEC on both ends. Optionally set O_NONBLOCK on the write end.
    private func makePipe(nonblockWrite: Bool = false) throws -> (read: CInt, write: CInt) {
        var fds: [CInt] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw ContainerizationError(.internalError, message: "fsnotify: pipe failed: errno \(errno)")
        }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        if nonblockWrite {
            let flags = fcntl(fds[1], F_GETFL)
            _ = fcntl(fds[1], F_SETFL, flags | O_NONBLOCK)
        }
        return (read: fds[0], write: fds[1])
    }
}

#endif
