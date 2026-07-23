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

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

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
    var kernel: String = Self.defaultKernelPath

    #if arch(arm64)
    private static let kernelCandidates = ["./bin/vmlinux-arm64"]
    #elseif arch(x86_64)
    private static let kernelCandidates = ["./bin/vmlinuz-x86_64", "./bin/vmlinux-x86_64"]
    #else
    private static let kernelCandidates = ["./bin/vmlinux"]
    #endif

    private static let defaultKernelPath: String = {
        let fm = FileManager.default
        for candidate in kernelCandidates where fm.fileExists(atPath: candidate) {
            return candidate
        }
        return kernelCandidates[0]
    }()

    @Option(name: .shortAndLong, help: "Maximum number of concurrent tests")
    var maxConcurrency: Int = 4

    @Option(name: .shortAndLong, help: "Only run tests whose names contain this string")
    var filter: String?

    #if os(Linux)
    @Option(name: .long, help: "Path to cloud-hypervisor binary (Linux only). Defaults to PATH lookup.")
    var chBinary: String?

    @Option(name: .long, help: "Path to virtiofsd binary (Linux only). Defaults to PATH lookup.")
    var virtiofsdBinary: String?
    #endif

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

        let testKernel = Kernel(path: .init(filePath: kernel), platform: .linuxArm)
        // Intentionally NOT adding `debug` or `earlycon=pl011,...` here.
        // Both look free, but each costs real wall-clock per VM boot:
        //   * `debug` floods printk through hvc0 (which CH writes to the
        //     bootlog file).
        //   * `earlycon=pl011,...` routes every early-boot printk character
        //     through pl011 MMIO traps into CH's serial emulator. With CH's
        //     pl011 wired to a file (see CHVirtualMachineInstance.serialConfig)
        //     each character is a synchronous file write and ~50–80 ms of
        //     dmesg quantization showed up in measurements — adding ~1.5 s
        //     to every VM boot before bootconsole hands over to virtio_console.
        // Re-add either as a one-shot when actively diagnosing kernel boot.
        let image = try await Self.fetchImage(reference: reference, store: store)
        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")

        // Unpack to shared location with coordination to prevent concurrent unpacks
        let fsPath = Self.testDir.appending(component: image.digest)
        let fs = try await Self.unpackCoordinator.unpack(key: fsPath.absolutePath()) {
            do {
                let unpacker = EXT4Unpacker(capacityInBytes: 2.gib())
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

        // Reap any per-test artifacts left over from prior tests. With
        // `--max-concurrency 1` (linux-integration default) this runs after
        // the previous test has fully completed, so it's race-free; on
        // macOS where tests can run in parallel we just keep all files —
        // disk usage isn't a concern there. Each per-test bootstrap clones
        // a ~2GB rootfs and a ~512MB initfs, so without reaping the dev
        // container fills its CoW layer in ~10 tests.
        if self.maxConcurrency == 1 {
            let preserve = fsPath.absolutePath()
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: Self.testDir,
                includingPropertiesForKeys: nil
            ) {
                for url in entries where url.absolutePath() != preserve {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        // Clone to test-specific path
        let clPath = Self.testDir.appending(component: "\(testID).ext4").absolutePath()
        try? FileManager.default.removeItem(atPath: clPath)

        let cl = try fs.clone(to: clPath)

        // Per-test clone of the init.block. The init.block is supposed to be
        // mounted read-only (kernel cmdline + readonly=true on the virtio-blk
        // device for both VZ and CH), but sharing the same backing file across
        // concurrent CH VMs has surfaced "internalError: mount" cascades on
        // Linux/CH after a single test failure — symptomatic of the file
        // entering a bad state when one CH instance is killed mid-flight.
        // Cloning per test isolates each VM from any cross-test fallout.
        let initClonePath = Self.testDir.appending(component: "\(testID).init.block").absolutePath()
        try? FileManager.default.removeItem(atPath: initClonePath)
        let initfsPerTest = try initfs.clone(to: initClonePath)

        // Create bootLog directory and per-container bootLog path
        let bootlogDirURL = URL(filePath: bootlogDir)
        try? FileManager.default.createDirectory(at: bootlogDirURL, withIntermediateDirectories: true)
        let bootlogURL = bootlogDirURL.appendingPathComponent("\(testID).log")

        let vmm: any VirtualMachineManager = try Self.makeVMM(
            kernel: testKernel,
            initialFilesystem: initfsPerTest,
            chBinary: Self.chBinaryOverride(for: self),
            virtiofsdBinary: Self.virtiofsdBinaryOverride(for: self)
        )

        return (
            cl,
            vmm,
            image,
            BootLog.file(path: bootlogURL)
        )
    }

    private static func chBinaryOverride(for suite: IntegrationSuite) -> String? {
        #if os(Linux)
        return suite.chBinary
        #else
        _ = suite
        return nil
        #endif
    }

    private static func virtiofsdBinaryOverride(for suite: IntegrationSuite) -> String? {
        #if os(Linux)
        return suite.virtiofsdBinary
        #else
        _ = suite
        return nil
        #endif
    }

    private static func makeVMM(
        kernel: Kernel,
        initialFilesystem: Containerization.Mount,
        chBinary: String?,
        virtiofsdBinary: String?
    ) throws -> any VirtualMachineManager {
        #if os(macOS)
        _ = chBinary
        _ = virtiofsdBinary
        return VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initialFilesystem,
            group: Self.eventLoop
        )
        #elseif os(Linux)
        return try CHVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initialFilesystem,
            chBinary: chBinary.map { URL(fileURLWithPath: $0) },
            virtiofsdBinary: virtiofsdBinary.map { URL(fileURLWithPath: $0) },
            group: Self.eventLoop,
            logger: log
        )
        #endif
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
        #if os(Linux)
        let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        #else
        let resource = RLIMIT_NOFILE
        #endif

        guard getrlimit(resource, &limits) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        limits.rlim_cur = 65536
        limits.rlim_max = 65536

        guard setrlimit(resource, &limits) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }

    #if os(macOS)
    private func macOS26Tests() -> [Test] {
        if #available(macOS 26.0, *) {
            return [
                Test("container interface custom MTU", testInterfaceMTU),
                Test("container networking disabled", testNetworkingDisabled),
                Test("container networking enabled", testNetworkingEnabled),
                Test("container networking enabled ipv6", testNetworkingEnabledIPv6),
                Test("container IPv6 address", testIPv6AddressAdd),
                Test("container IPv6 default route", testIPv6DefaultRoute),
                Test("container IPv6 gateway outside subnet", testIPv6GatewayOutsideSubnet),
                Test("container IPv6 only default route", testIPv6OnlyDefaultRoute),
                Test("container IPv6 only gateway outside subnet", testIPv6OnlyGatewayOutsideSubnet),
                Test("container IPv6 dual stack", testIPv6DualStack),
                Test("pod IPv6 address", testPodIPv6AddressAdd),
            ]
        }
        return []
    }
    #endif

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
        let suiteStarted = Date().timeIntervalSinceReferenceDate
        log.info("starting integration suite\n")

        let crossPlatformTests: [Test] = [
            // Process basics
            Test("process true", testProcessTrue),
            Test("process false", testProcessFalse),
            Test("process echo hi", testProcessEchoHi),
            Test("process no executable", testProcessNoExecutable),
            Test("process user", testProcessUser),
            Test("process stdin", testProcessStdin),
            Test("process home envvar", testProcessHomeEnvvar),
            Test("process custom home envvar", testProcessCustomHomeEnvvar),
            Test("process tty ensure TERM", testProcessTtyEnvvar),

            // Hostname / hosts
            Test("container hostname", testHostname),
            Test("container hostname defaults to container id", testHostnameDefaultsToContainerID),
            Test("container hosts", testHostsFile),

            // Statistics / cgroups / memory
            Test("container statistics", testContainerStatistics),
            Test("container cgroup limits", testCgroupLimits),
            Test("container memory events OOM kill", testMemoryEventsOOMKill),

            // Console / boot / lifecycle
            Test("container no serial console", testNoSerialConsole),
            Test("container non-closure constructor", testNonClosureConstructor),
            Test("container test large stdio ingest", testLargeStdioOutput),
            Test("container bootlog using filehandle", testBootLogFileHandle),
            Test("process delete idempotency", testProcessDeleteIdempotency),
            Test("multiple execs without delete", testMultipleExecsWithoutDelete),

            // Capabilities
            Test("container capabilities sys admin", testCapabilitiesSysAdmin),
            Test("container capabilities net admin", testCapabilitiesNetAdmin),
            Test("container capabilities OCI default", testCapabilitiesOCIDefault),
            Test("container capabilities all capabilities", testCapabilitiesAllCapabilities),
            Test("container capabilities file ownership", testCapabilitiesFileOwnership),

            // Masked / read-only paths
            Test("container default masked and read-only paths", testDefaultMaskedAndReadonlyPaths),

            // Stat / Copy
            Test("container stat", testStat),
            Test("container copy in", testCopyIn),
            Test("container copy in file to existing directory", testCopyInFileToExistingDirectory),
            Test("container copy in file to missing directory fails", testCopyInFileToMissingDirectoryFails),
            Test("container copy in directory over existing file fails", testCopyInDirectoryOverExistingFileFails),
            Test("container copy out", testCopyOut),
            Test("container copy large file", testCopyLargeFile),
            Test("container copy in directory", testCopyInDirectory),
            Test("container copy out directory", testCopyOutDirectory),
            Test("container copy empty file", testCopyEmptyFile),
            Test("container copy empty directory", testCopyEmptyDirectory),
            Test("container copy binary file", testCopyBinaryFile),
            Test("container copy multiple files", testCopyMultipleFiles),
            Test("container copy directory round trip", testCopyDirectoryRoundTrip),
            Test("container copy in create parents", testCopyInCreateParents),
            Test("container copy file permissions", testCopyFilePermissions),
            Test("container copy large directory", testCopyLargeDirectory),

            // Read-only / writable layers
            Test("container read-only rootfs", testReadOnlyRootfs),
            Test("container read-only rootfs hosts file", testReadOnlyRootfsHostsFileWritten),
            Test("container read-only rootfs DNS", testReadOnlyRootfsDNSConfigured),
            Test("container writable layer", testWritableLayer),
            Test("container writable layer journal writeback", testWritableLayerJournalWriteback),
            Test("container writable layer journal ordered", testWritableLayerJournalOrdered),
            Test("container writable layer journal data", testWritableLayerJournalData),
            Test("container writable layer preserves lower", testWritableLayerPreservesLowerLayer),
            Test("container writable layer reads from lower", testWritableLayerReadsFromLower),
            Test("container writable layer with ro lower", testWritableLayerWithReadOnlyLower),
            Test("container writable layer size", testWritableLayerSize),
            Test("container writable layer DNS and hosts", testWritableLayerWithDNSAndHosts),

            // Stdin / stdout / exec
            Test("large stdin input", testLargeStdinInput),
            Test("exec large stdin input", testExecLargeStdinInput),
            Test("exec custom path resolution", testExecCustomPathResolution),
            Test("stdin explicit close", testStdinExplicitClose),
            Test("stdin binary data", testStdinBinaryData),
            Test("stdin multiple chunks", testStdinMultipleChunks),
            Test("stdin very large", testStdinVeryLarge),

            // RLimit
            Test("container rlimit open files", testRLimitOpenFiles),
            Test("container rlimit multiple", testRLimitMultiple),
            Test("container rlimit exec", testRLimitExec),

            // useInit
            Test("container useInit basic", testUseInitBasic),
            Test("container useInit exit code propagation", testUseInitExitCodePropagation),
            Test("container useInit signal forwarding", testUseInitSignalForwarding),
            Test("container useInit zombie reaping", testUseInitZombieReaping),
            Test("container useInit with terminal", testUseInitWithTerminal),
            Test("container useInit with stdin", testUseInitWithStdin),

            // Sysctl / security / workingDir
            Test("container sysctl", testSysctl),
            Test("container sysctl multiple", testSysctlMultiple),
            Test("container noNewPrivileges", testNoNewPrivileges),
            Test("container noNewPrivileges disabled", testNoNewPrivilegesDisabled),
            Test("container noNewPrivileges exec", testNoNewPrivilegesExec),
            Test("container workingDir created", testWorkingDirCreated),
            Test("container workingDir exec created", testWorkingDirExecCreated),

            // VM resource overhead
            Test("container VM resource overhead", testVMResourceOverhead),

            // Pods
            Test("pod single container", testPodSingleContainer),
            Test("pod multiple containers", testPodMultipleContainers),
            Test("pod container output", testPodContainerOutput),
            Test("pod concurrent containers", testPodConcurrentContainers),
            Test("pod exec in container", testPodExecInContainer),
            Test("pod exec in container env", testPodExecInContainerEnv),
            Test("pod container hostname", testPodContainerHostname),
            Test("pod container hostname defaults to container id", testPodContainerHostnameDefaultsToContainerID),
            Test("pod stop container idempotency", testPodStopContainerIdempotency),
            Test("pod list containers", testPodListContainers),
            Test("pod container statistics", testPodContainerStatistics),
            Test("pod memory events OOM kill", testPodMemoryEventsOOMKill),
            Test("pod container resource limits", testPodContainerResourceLimits),
            Test("pod container filesystem isolation", testPodContainerFilesystemIsolation),
            Test("pod container PID namespace isolation", testPodContainerPIDNamespaceIsolation),
            Test("pod container independent resource limits", testPodContainerIndependentResourceLimits),
            Test("pod shared PID namespace", testPodSharedPIDNamespace),
            Test("pod read-only rootfs", testPodReadOnlyRootfs),
            Test("pod read-only rootfs DNS", testPodReadOnlyRootfsDNSConfigured),
            Test("pod container hosts config", testPodContainerHostsConfig),
            Test("pod multiple containers different DNS", testPodMultipleContainersDifferentDNS),
            Test("pod multiple containers different hosts", testPodMultipleContainersDifferentHosts),
            Test("pod level DNS", testPodLevelDNS),
            Test("pod level DNS with container override", testPodLevelDNSWithContainerOverride),
            Test("pod level hosts", testPodLevelHosts),
            Test("pod level hosts with container override", testPodLevelHostsWithContainerOverride),
            Test("pod level hostname", testPodLevelHostname),
            Test("pod level hostname with container override", testPodLevelHostnameWithContainerOverride),
            Test("pod rlimit open files", testPodRLimitOpenFiles),
            Test("pod rlimit exec", testPodRLimitExec),
            Test("pod useInit basic", testPodUseInitBasic),
            Test("pod useInit exit code propagation", testPodUseInitExitCodePropagation),
            Test("pod useInit signal forwarding", testPodUseInitSignalForwarding),
            Test("pod useInit multiple containers", testPodUseInitMultipleContainers),
            Test("pod useInit with shared PID namespace", testPodUseInitWithSharedPIDNamespace),
            Test("pod sysctl", testPodSysctl),
            Test("pod sysctl multiple containers", testPodSysctlMultipleContainers),
            Test("pod invalid volume reference", testPodInvalidVolumeReference),
            Test("pod duplicate volume name", testPodDuplicateVolumeName),

            // Mounts / virtiofs shares (cross-platform: VZ on macOS, virtiofsd on Linux/CH).
            Test("container mount", testMounts),
            Test("container single file mount", testSingleFileMount),
            Test("container single file mount read-only", testSingleFileMountReadOnly),
            Test("container single file mount write-back", testSingleFileMountWriteBack),
            Test("container single file mount symlink", testSingleFileMountSymlink),
            Test("container duplicate virtiofs mount", testDuplicateVirtiofsMount),
            Test("container duplicate virtiofs mount via symlink", testDuplicateVirtiofsMountViaSymlink),
            Test("container mount sort by depth", testMountsSortedByDepth),
            Test("pod single file mount", testPodSingleFileMount),
        ]

        #if os(macOS)
        let macOSOnlyTests: [Test] =
            [
                // ContainerManager-based tests (ContainerManager is macOS-only)
                Test("container stop idempotency", testContainerStopIdempotency),
                Test("container manager", testContainerManagerCreate),
                Test("container reuse", testContainerReuse),
                Test("container /dev/console", testContainerDevConsole),

                // Nested virtualization (VZ-only feature)
                Test("nested virt", testNestedVirtualizationEnabled),

                // Filesystem operations (TODO: promote to cross-platform once verified on CH)
                Test("container frozen ext4 clone", testFrozenExt4Clone),
                Test("container trim ext4 clone", testTrimExt4Clone),

                // Unix socket forwarding (dynamic vsock listen exceeds CH's prebound stdio pool)
                Test("unix socket into guest", testUnixSocketIntoGuest),
                Test("unix socket into guest long container id", testUnixSocketIntoGuestLongContainerID),
                Test("unix socket into guest symlink", testUnixSocketIntoGuestSymlink),
                Test("pod unix socket into guest symlink", testPodUnixSocketIntoGuestSymlink),

                // High-concurrency stdio (exceeds CH's prebound stdio pool size)
                Test("multiple concurrent processes", testMultipleConcurrentProcesses),
                Test("multiple concurrent processes with output stress", testMultipleConcurrentProcessesOutputStress),

                // NBD volumes (test infra is macOS-only)
                Test("container NBD mount", testContainerNBDMount),
                Test("container NBD read-only", testContainerNBDReadOnly),
                Test("container NBD raw block", testContainerNBDRawBlock),
                Test("container NBD volume identity", testContainerNBDVolumeIdentity),
                Test("pod shared NBD volume", testPodSharedNBDVolume),
                Test("pod multiple NBD volumes", testPodMultipleNBDVolumes),
                Test("pod unreferenced NBD volume", testPodUnreferencedVolume),
                Test("pod NBD volume persistence", testPodNBDVolumePersistence),
                Test("pod NBD concurrent writes", testPodNBDConcurrentWrites),
                Test("pod NBD volume identity", testPodNBDVolumeIdentity),
                Test("pod filesystem operation", testPodFilesystemOperation),
                Test("pod shared disk image volume", testPodSharedDiskImageVolume),
                Test("pod shared tmpfs volume", testPodSharedTmpfsVolume),
            ] + macOS26Tests()
        let tests: [Test] = crossPlatformTests + macOSOnlyTests
        #else
        // Hotplug into a running pod VM is CH-only (VZ has no runtime hotplug),
        // and no pod test elsewhere exercises addContainer-after-create.
        let linuxOnlyTests: [Test] = [
            Test("pod hotplug block rootfs", testPodHotplugBlockRootfs),
            Test("pod hotplug virtiofs rootfs", testPodHotplugVirtiofsRootfs),
        ]
        let tests: [Test] = crossPlatformTests + linuxOnlyTests
        #endif

        let filteredTests: [Test]
        if let filter {
            // Comma-separated; ANY pattern matching the test name keeps it.
            // E.g. `--filter "container mount,pod single file"`.
            let patterns = filter.split(separator: ",").map { String($0) }
            filteredTests = tests.filter { test in
                patterns.contains { test.name.contains($0) }
            }
            log.info("filter '\(filter)' matched \(filteredTests.count)/\(tests.count) tests")
        } else {
            filteredTests = tests
        }

        let passed: Atomic<Int> = Atomic(0)
        let skipped: Atomic<Int> = Atomic(0)

        await withTaskGroup(of: Void.self) { group in
            let jobQueue = JobQueue(filteredTests)
            for _ in 0..<maxConcurrency {
                group.addTask { @Sendable in
                    while let job = jobQueue.pop() {
                        do {
                            log.info("test \(job.name) started...")

                            let started = Date().timeIntervalSinceReferenceDate
                            try await job.work()
                            let lasted = Date().timeIntervalSinceReferenceDate - started

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

        let ended = Date().timeIntervalSinceReferenceDate - suiteStarted
        var finishingText = "\n\nIntegration suite completed in \(ended)s with \(passedCount)/\(filteredTests.count) passed"
        if skipped.load(ordering: .acquiring) > 0 {
            finishingText += " and \(skippedCount)/\(filteredTests.count) skipped"
        }
        finishingText += "!"

        log.info("\(finishingText)")

        try? FileManager.default.removeItem(at: Self.testDir)
        if passedCount + skippedCount < filteredTests.count {
            log.error("❌")
            throw ExitCode(1)
        }
    }
}
