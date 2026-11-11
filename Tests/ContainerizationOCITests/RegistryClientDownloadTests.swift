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
import ContainerizationExtras
import Crypto
import Darwin
import Foundation
import NIOPosix
import Synchronization
import Testing

@testable import ContainerizationOCI

@Suite("RegistryClient download file lifetime")
struct RegistryClientDownloadTests {
    enum Scenario: CaseIterable, Sendable {
        case success
        case cancellation
        case siblingFailure
        case registryFailure
    }

    private enum DownloadError: Error, Equatable {
        case siblingFailed
    }

    @Test("Download closes its file before returning", .timeLimit(.minutes(1)), arguments: Scenario.allCases)
    func downloadClosesFile(scenario: Scenario) async throws {
        let body = Data(repeating: 0x5a, count: 2 * 1024 * 1024)
        let descriptor = Descriptor(mediaType: MediaTypes.imageLayer, digest: SHA256.hash(data: body).digestString, size: Int64(body.count))
        let server = try await MockRegistryServer(eventLoopGroup: MultiThreadedEventLoopGroup.singleton) { _ in
            .status(scenario == .registryFailure ? .notFound : .ok, body: body)
        }
        defer { Task { try? await server.shutdown() } }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("blob")
        let client = RegistryClient(host: "127.0.0.1", scheme: "http", port: server.port)
        let received = Mutex<Int64>(0)
        let observed = Mutex<[OpenFile]>([])
        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish()
            resume.continuation.finish()
        }

        let progress: ProgressHandler = { events in
            let shouldCancel = received.withLock { count in
                let previous = count
                for event in events {
                    if case .addSize(let size) = event {
                        count += size
                    }
                }
                return previous < 1024 * 1024 && count >= 1024 * 1024
            }
            guard shouldCancel else { return }
            // Detaching a transactional NIO file can unlink its original path.
            // Capture the descriptor identity while F_GETPATH can still resolve it.
            let handles = Self.openFiles(in: directory)
            #expect(!handles.isEmpty, "Download file must be observable while writing")
            observed.withLock { $0 = handles }
            switch scenario {
            case .cancellation:
                withUnsafeCurrentTask { $0?.cancel() }
            case .siblingFailure:
                started.continuation.yield(())
                // A failed sibling cancels this suspended download through the task group.
                for await _ in resume.stream {}
            case .success, .registryFailure:
                break
            }
        }

        let download = Task {
            if scenario == .siblingFailure {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        defer { started.continuation.finish() }
                        _ = try await client.fetchBlob(name: "test/image", descriptor: descriptor, into: file, progress: progress)
                    }
                    group.addTask {
                        var iterator = started.stream.makeAsyncIterator()
                        _ = try #require(await iterator.next())
                        throw DownloadError.siblingFailed
                    }
                    _ = try await group.next()
                }
                return
            }
            let (size, digest) = try await client.fetchBlob(name: "test/image", descriptor: descriptor, into: file, progress: progress)
            #expect(size == Int64(body.count))
            #expect(digest.digestString == descriptor.digest)
        }

        if scenario == .success {
            try await download.value
            #expect(try Data(contentsOf: file) == body)
            #expect(received.withLock { $0 } == Int64(body.count))
        } else if scenario == .siblingFailure {
            await #expect(throws: DownloadError.siblingFailed) {
                try await download.value
            }
        } else {
            await #expect(throws: (any Error).self) {
                try await download.value
            }
        }
        if scenario == .cancellation || scenario == .siblingFailure {
            #expect(received.withLock { $0 } >= 1024 * 1024)
        }

        // Restrict observations to this test's directory: other suites may open files concurrently.
        var handles = observed.withLock { $0.filter(\.isOpen) }
        for handle in Self.openFiles(in: directory) where !handles.contains(where: { $0.descriptor == handle.descriptor }) {
            handles.append(handle)
        }
        defer {
            // Release only confirmed leaked test files, so a failing regression does not exhaust FDs.
            for handle in handles where handle.isOpen {
                _ = Darwin.close(handle.descriptor)
            }
        }
        #expect(handles.isEmpty, "Download retained \(handles.count) file handles")
        try FileManager.default.removeItem(at: directory)
        let unlinked = handles.filter { $0.isOpen }
        #expect(unlinked.isEmpty, "Deleted download still holds \(unlinked.reduce(Int64(0)) { $0 + $1.allocatedBytes }) allocated bytes")
    }

    private struct OpenFile: Sendable {
        let descriptor: Int32
        let device: dev_t
        let inode: ino_t
        let allocatedBytes: Int64

        var isOpen: Bool {
            var info = stat()
            return fstat(descriptor, &info) == 0 && info.st_dev == device && info.st_ino == inode
        }
    }

    private static func openFiles(in directory: URL) -> [OpenFile] {
        // Use POSIX canonicalization to match F_GETPATH's /private/var spelling.
        guard let resolved = realpath(directory.path, nil) else { return [] }
        defer { free(resolved) }
        let prefix = String(cString: resolved) + "/"
        var files: [OpenFile] = []
        for descriptor in 0..<getdtablesize() {
            var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &path) == 0 else { continue }
            guard String(decoding: path.prefix { $0 != 0 }, as: UTF8.self).hasPrefix(prefix) else { continue }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { continue }
            files.append(OpenFile(descriptor: descriptor, device: info.st_dev, inode: info.st_ino, allocatedBytes: info.st_blocks * 512))
        }
        return files
    }
}
#endif
