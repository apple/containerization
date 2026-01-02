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

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import NIOCore
import NIOPosix
import Synchronization

actor UnpackCoordinator {
    private var inFlight: [String: Task<Containerization.Mount, Error>] = [:]

    func unpack(
        key: String,
        operation: @escaping @Sendable () async throws -> Containerization.Mount
    ) async throws -> Containerization.Mount {
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task {
            try await operation()
        }
        inFlight[key] = task

        defer {
            inFlight.removeValue(forKey: key)
        }

        return try await task.value
    }
}

struct Test: Sendable {
    var name: String
    var work: @Sendable () async throws -> Void

    init(_ name: String, _ work: @escaping @Sendable () async throws -> Void) {
        self.name = name
        self.work = work
    }
}

final class JobQueue<T>: Sendable where T: Sendable {
    struct State: Sendable {
        var next = 0
        var jobs: [T]
    }

    private let lock: Mutex<State>
    init(_ jobs: [T]) {
        self.lock = Mutex(State(jobs: jobs))
    }

    func pop() -> T? {
        self.lock.withLock { state in
            guard state.next < state.jobs.count else {
                return nil
            }
            defer {
                state.next += 1
            }
            return state.jobs[state.next]
        }
    }
}

let log = {
    LoggingSystem.bootstrap(StreamLogHandler.standardError)
    var log = Logger(label: "com.apple.containerization")
    log.logLevel = .debug
    return log
}()

enum IntegrationError: Swift.Error {
    case assert(msg: String)
    case noOutput
}

struct SkipTest: Swift.Error, CustomStringConvertible {
    let reason: String

    var description: String {
        reason
    }
}

@main
struct IntegrationSuite: AsyncParsableCommand {
    static let appRoot: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("com.apple.containerization")
    }()

    private static let _contentStore: ContentStore = {
        try! LocalContentStore(path: appRoot.appending(path: "content"))
    }()

    private static let _imageStore: ImageStore = {
        try! ImageStore(
            path: appRoot,
            contentStore: contentStore
        )
    }()

    static let _testDir: URL = {
        FileManager.default.uniqueTemporaryDirectory(create: true)
    }()

    static var testDir: URL {
        _testDir
    }

    static var imageStore: ImageStore {
        _imageStore
    }

    static var contentStore: ContentStore {
        _contentStore
    }

    static let initImage = "vminit:latest"

    private static let unpackCoordinator = UnpackCoordinator()

    @Option(name: .shortAndLong, help: "Path to a directory for boot logs")
    var bootlogDir: String = "./bin/integration-bootlogs"

    @Option(name: .shortAndLong, help: "Path to a kernel binary")
    var kernel: String = "./bin/vmlinux"

    @Option(name: .shortAndLong, help: "Maximum number of concurrent tests")
    var maxConcurrency: Int = 4

    static func binPath(name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("bin")
            .appendingPathComponent(name)
    }

    static let eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    func bootstrap(_ testID: String) async throws -> (rootfs: Containerization.Mount, vmm: VirtualMachineManager, image: Containerization.Image, bootLog: BootLog) {
        let reference = "ghcr.io/linuxcontainers/alpine:3.20"
        let store = Self.imageStore

        let initImage = try await store.getInitImage(reference: Self.initImage)
        let initfs = try await {
            let p = Self.binPath(name: "init.block")
            do {
                return try await initImage.initBlock(at: p, for: .linuxArm)
            } catch let err as ContainerizationError {
                guard err.code == .exists else {
                    throw err
                }
                return .block(
                    format: "ext4",
                    source: p.absolutePath(),
                    destination: "/",
                    options: ["ro"]
                )
            }
        }()

        var testKernel = Kernel(path: .init(filePath: kernel), platform: .linuxArm)
        testKernel.commandLine.addDebug()
        let image = try await Self.fetchImage(reference: reference, store: store)
        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")

        // Unpack to shared location with coordination to prevent concurrent unpacks
        let fsPath = Self.testDir.appending(component: image.digest)
        let fs = try await Self.unpackCoordinator.unpack(key: fsPath.absolutePath()) {
            do {
                let unpacker = EXT4Unpacker(blockSizeInBytes: 2.gib())
                return try await unpacker.unpack(image, for: platform, at: fsPath)
            } catch let err as ContainerizationError {
                if err.code == .exists {
                    return .block(
                        format: "ext4",
                        source: fsPath.absolutePath(),
                        destination: "/",
                        options: []
                    )
                }
                throw err
            }
        }

        // Clone to test-specific path
        let clPath = Self.testDir.appending(component: "\(testID).ext4").absolutePath()
        try? FileManager.default.removeItem(atPath: clPath)

        let cl = try fs.clone(to: clPath)

        // Create bootLog directory and per-container bootLog path
        let bootlogDirURL = URL(filePath: bootlogDir)
        try? FileManager.default.createDirectory(at: bootlogDirURL, withIntermediateDirectories: true)
        let bootlogURL = bootlogDirURL.appendingPathComponent("\(testID).log")

        return (
            cl,
            VZVirtualMachineManager(
                kernel: testKernel,
                initialFilesystem: initfs,
                group: Self.eventLoop
            ),
            image,
            BootLog.file(path: bootlogURL)
        )
    }

    static func fetchImage(reference: String, store: ImageStore) async throws -> Containerization.Image {
        do {
            return try await store.get(reference: reference)
        } catch let error as ContainerizationError {
            if error.code == .notFound {
                return try await store.pull(reference: reference)
            }
            throw error
        }
    }

    static func adjustLimits() throws {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        limits.rlim_cur = 65536
        limits.rlim_max = 65536

        guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }

    // Why does this exist?
    //
    // We need the virtualization entitlement to execute these tests.
    // There currently does not exist a straightforward way to do this
    // in a pure swift package.
    //
    // In order to not have a dependency on xcode, we create an executable
    // for our integration tests that can be signed then ran.
    //
    // We also can't import Testing as it expects to be run from a runner.
    // Hopefully this improves over time.
    func run() async throws {
        try Self.adjustLimits()
        let suiteStarted = CFAbsoluteTimeGetCurrent()
        log.info("starting integration suite\n")

        let tests: [Test] = [
            // Containers
            Test("process true", testProcessTrue),
            Test("process false", testProcessFalse),
            Test("process echo hi", testProcessEchoHi),
            Test("process user", testProcessUser),
            Test("process stdin", testProcessStdin),
            Test("process home envvar", testProcessHomeEnvvar),
            Test("process custom home envvar", testProcessCustomHomeEnvvar),
            Test("process tty ensure TERM", testProcessTtyEnvvar),
            Test("multiple concurrent processes", testMultipleConcurrentProcesses),
            Test("multiple concurrent processes with output stress", testMultipleConcurrentProcessesOutputStress),
            Test("container hostname", testHostname),
            Test("container hosts", testHostsFile),
            Test("container mount", testMounts),
            Test("container stop idempotency", testContainerStopIdempotency),
            Test("nested virt", testNestedVirtualizationEnabled),
            Test("container manager", testContainerManagerCreate),
            Test("container reuse", testContainerReuse),
            Test("container /dev/console", testContainerDevConsole),
            Test("container statistics", testContainerStatistics),
            Test("container cgroup limits", testCgroupLimits),
            Test("container no serial console", testNoSerialConsole),
            Test("unix socket into guest", testUnixSocketIntoGuest),
            Test("container non-closure constructor", testNonClosureConstructor),
            Test("container test large stdio ingest", testLargeStdioOutput),
            Test("process delete idempotency", testProcessDeleteIdempotency),
            Test("multiple execs without delete", testMultipleExecsWithoutDelete),
            Test("container bootlog using filehandle", testBootLogFileHandle),
            Test("container capabilities sys admin", testCapabilitiesSysAdmin),
            Test("container capabilities net admin", testCapabilitiesNetAdmin),
            Test("container capabilities OCI default", testCapabilitiesOCIDefault),
            Test("container capabilities all capabilities", testCapabilitiesAllCapabilities),
            Test("container capabilities file ownership", testCapabilitiesFileOwnership),
            Test("container copy in", testCopyIn),
            Test("container copy out", testCopyOut),
            Test("container copy large file", testCopyLargeFile),
            Test("container read-only rootfs", testReadOnlyRootfs),
            Test("container read-only rootfs hosts file", testReadOnlyRootfsHostsFileWritten),
            Test("container read-only rootfs DNS", testReadOnlyRootfsDNSConfigured),

            // Pods
            Test("pod single container", testPodSingleContainer),
            Test("pod multiple containers", testPodMultipleContainers),
            Test("pod container output", testPodContainerOutput),
            Test("pod concurrent containers", testPodConcurrentContainers),
            Test("pod exec in container", testPodExecInContainer),
            Test("pod container hostname", testPodContainerHostname),
            Test("pod stop container idempotency", testPodStopContainerIdempotency),
            Test("pod list containers", testPodListContainers),
            Test("pod container statistics", testPodContainerStatistics),
            Test("pod container resource limits", testPodContainerResourceLimits),
            Test("pod container filesystem isolation", testPodContainerFilesystemIsolation),
            Test("pod container PID namespace isolation", testPodContainerPIDNamespaceIsolation),
            Test("pod container independent resource limits", testPodContainerIndependentResourceLimits),
            Test("pod shared PID namespace", testPodSharedPIDNamespace),
            Test("pod read-only rootfs", testPodReadOnlyRootfs),
            Test("pod read-only rootfs DNS", testPodReadOnlyRootfsDNSConfigured),
        ]

        let passed: Atomic<Int> = Atomic(0)
        let skipped: Atomic<Int> = Atomic(0)

        await withTaskGroup(of: Void.self) { group in
            let jobQueue = JobQueue(tests)
            for _ in 0..<maxConcurrency {
                group.addTask { @Sendable in
                    while let job = jobQueue.pop() {
                        do {
                            log.info("test \(job.name) started...")

                            let started = CFAbsoluteTimeGetCurrent()
                            try await job.work()
                            let lasted = CFAbsoluteTimeGetCurrent() - started

                            log.info("✅ test \(job.name) complete in \(lasted)s.")
                            passed.add(1, ordering: .relaxed)
                        } catch let err as SkipTest {
                            log.info("⏭️ skipped test: \(err)")
                            skipped.add(1, ordering: .relaxed)
                        } catch {
                            log.error("❌ test \(job.name) failed: \(error)")
                        }
                    }
                }
            }
            await group.waitForAll()
        }

        let passedCount = passed.load(ordering: .acquiring)
        let skippedCount = skipped.load(ordering: .acquiring)

        let ended = CFAbsoluteTimeGetCurrent() - suiteStarted
        var finishingText = "\n\nIntegration suite completed in \(ended)s with \(passedCount)/\(tests.count) passed"
        if skipped.load(ordering: .acquiring) > 0 {
            finishingText += " and \(skippedCount)/\(tests.count) skipped"
        }
        finishingText += "!"

        log.info("\(finishingText)")

        try? FileManager.default.removeItem(at: Self.testDir)
        if passedCount + skippedCount < tests.count {
            log.error("❌")
            throw ExitCode(1)
        }
    }
}
