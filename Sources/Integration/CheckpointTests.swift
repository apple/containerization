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

#if os(macOS)
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationIO
import ContainerizationOS
import Foundation
import Synchronization

/// A stdin whose input the test controls after the container has started. It can be streamed
/// more than once, because a checkpoint reconnects the process's stdin: input sent while nothing
/// is connected waits for the next connection.
private final class LiveStdin: ReaderStream, Sendable {
    private struct State {
        var generation = 0
        var continuation: AsyncStream<Data>.Continuation?
        var pending: [Data] = []
    }

    private let state = Mutex(State())

    func stream() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let generation = self.state.withLock { state -> Int in
            state.generation += 1
            state.continuation = continuation
            for data in state.pending {
                continuation.yield(data)
            }
            state.pending.removeAll()
            return state.generation
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                if state.generation == generation {
                    state.continuation = nil
                }
            }
        }
        return stream
    }

    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        self.state.withLock { state in
            if let continuation = state.continuation {
                continuation.yield(data)
            } else {
                state.pending.append(data)
            }
        }
    }
}

extension IntegrationSuite {
    /// A process with state that only memory can carry: it numbers the lines it reads.
    private static let lineCounter = ["/bin/sh", "-c", "n=0; while read l; do n=$((n+1)); echo \"$n:$l\"; done"]

    private func waitForOutput(
        _ buffer: BufferWriter,
        toContain expected: String,
        timeoutSeconds: Int = 30
    ) async throws {
        for _ in 0..<(timeoutSeconds * 10) {
            if String(decoding: buffer.data, as: UTF8.self).contains(expected) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IntegrationError.assert(
            msg: "timed out waiting for '\(expected)' in output '\(String(decoding: buffer.data, as: UTF8.self))'")
    }

    private func makeCheckpointScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Guest side: detaching a process's stdio for a checkpoint and attaching it again must leave
    /// the process running with working stdin and stdout, every time.
    func testCheckpointReattachesProcessIO() async throws {
        let id = "test-checkpoint-reattach-io"
        let bs = try await bootstrap(id)
        let scratch = try makeCheckpointScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stdin = LiveStdin()
        let stdout = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = Self.lineCounter
            config.process.stdin = stdin
            config.process.stdout = stdout
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            stdin.send("a")
            try await waitForOutput(stdout, toContain: "1:a")

            // The process keeps its state and its stdio across a checkpoint, more than once.
            try await container.checkpoint(to: scratch.appendingPathComponent("first"))
            stdin.send("b")
            try await waitForOutput(stdout, toContain: "2:b")

            try await container.checkpoint(to: scratch.appendingPathComponent("second"))
            stdin.send("c")
            try await waitForOutput(stdout, toContain: "3:c")

            // A checkpoint that cannot be taken must not disturb the process either.
            do {
                try await container.checkpoint(to: scratch.appendingPathComponent("first"))
                throw IntegrationError.assert(msg: "checkpoint to an existing directory should fail")
            } catch let error as ContainerizationError {
                guard error.code == .exists else {
                    throw error
                }
            }
            stdin.send("d")
            try await waitForOutput(stdout, toContain: "4:d")

            try await container.kill(.kill)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    /// The checkpoint directory carries the manifest and the machine state.
    func testCheckpointWritesBundle() async throws {
        let id = "test-checkpoint-bundle"
        let bs = try await bootstrap(id)
        let scratch = try makeCheckpointScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "300"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let bundle = scratch.appendingPathComponent("bundle")
            let ranWhilePaused = Mutex(false)
            try await container.checkpoint(to: bundle) {
                ranWhilePaused.withLock { $0 = true }
            }
            guard ranWhilePaused.withLock({ $0 }) else {
                throw IntegrationError.assert(msg: "whilePaused was not called")
            }

            let manifest = try LinuxContainer.Checkpoint.load(
                from: bundle.appendingPathComponent(LinuxContainer.Checkpoint.manifestName))
            guard manifest.id == id else {
                throw IntegrationError.assert(msg: "checkpoint id '\(manifest.id)' != '\(id)'")
            }
            guard
                FileManager.default.fileExists(
                    atPath: bundle.appendingPathComponent(LinuxContainer.Checkpoint.stateDirectoryName).path)
            else {
                throw IntegrationError.assert(msg: "checkpoint has no saved state")
            }

            // A failure while paused removes the checkpoint and is reported, and the container survives.
            struct PausedFailure: Swift.Error {}
            let failed = scratch.appendingPathComponent("failed")
            do {
                try await container.checkpoint(to: failed) { throw PausedFailure() }
                throw IntegrationError.assert(msg: "checkpoint should have failed")
            } catch is PausedFailure {}
            guard !FileManager.default.fileExists(atPath: failed.path) else {
                throw IntegrationError.assert(msg: "failed checkpoint was left behind")
            }

            try await container.kill(.kill)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    /// A real save and restore: the process in the restored machine carries on from the state it
    /// had when the checkpoint was taken, with its stdio connected to the new streams.
    func testCheckpointAndRestore() async throws {
        let id = "test-checkpoint-restore"
        let bs = try await bootstrap(id)
        let scratch = try makeCheckpointScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stdin = LiveStdin()
        let stdout = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = Self.lineCounter
            config.process.stdin = stdin
            config.process.stdout = stdout
            config.bootLog = bs.bootLog
        }

        let bundle = scratch.appendingPathComponent("bundle")
        let rootfsCopy = scratch.appendingPathComponent("rootfs.ext4")
        do {
            try await container.create()
            try await container.start()

            stdin.send("a")
            stdin.send("b")
            try await waitForOutput(stdout, toContain: "2:b")

            // The disk is not part of the checkpoint. Preserve it while the guest is frozen.
            let rootfsPath = URL(fileURLWithPath: bs.rootfs.source)
            try await container.checkpoint(to: bundle) {
                try FileManager.default.copyItem(at: rootfsPath, to: rootfsCopy)
            }

            // Nothing of the original machine is needed from here on.
            try await container.kill(.kill)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }

        let restoredBootstrap = try await bootstrap("\(id)-restored")
        let restoredStdin = LiveStdin()
        let restoredStdout = BufferWriter()
        let restoredRootfs = Containerization.Mount.block(
            format: "ext4",
            source: rootfsCopy.path,
            destination: "/",
            options: []
        )
        let restored = try LinuxContainer(id, rootfs: restoredRootfs, vmm: restoredBootstrap.vmm) { config in
            config.process.arguments = Self.lineCounter
            config.process.stdin = restoredStdin
            config.process.stdout = restoredStdout
            config.bootLog = restoredBootstrap.bootLog
        }

        do {
            // The init process is already running in the restored guest: no start().
            try await restored.create(from: bundle)

            // The counter is 2 in the saved memory; a fresh process would answer "1:c".
            restoredStdin.send("c")
            try await waitForOutput(restoredStdout, toContain: "3:c")

            try await restored.kill(.kill)
            try await restored.wait()
            try await restored.stop()
        } catch {
            try? await restored.stop()
            throw error
        }
    }

    /// A restore against a root filesystem or checkpoint that is not usable fails cleanly.
    func testRestoreFromMissingCheckpointFails() async throws {
        let id = "test-checkpoint-restore-missing"
        let bs = try await bootstrap(id)
        let scratch = try makeCheckpointScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/true"]
            config.bootLog = bs.bootLog
        }

        var failed = false
        do {
            try await container.create(from: scratch.appendingPathComponent("does-not-exist"))
        } catch {
            failed = true
        }
        try? await container.stop()
        guard failed else {
            throw IntegrationError.assert(msg: "restoring from a missing checkpoint should fail")
        }
    }
}
#endif
