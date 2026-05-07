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

import ArgumentParser
import CVersion
import Cgroup
import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation
import GRPCCore
import Logging
import NIOCore
import NIOPosix

#if os(Linux)
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import LCShim
#endif

public struct AgentCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Run the vminitd agent daemon"
    )

    private static let foregroundEnvVar = "FOREGROUND"
    public static let vsockPort = 1024

    @OptionGroup public var options: LogLevelOption

    public init() {}

    /// Bootstrap the vminitd environment and create an Initd server.
    /// Handles mounts, cgroups, memory monitoring, and all pre-serve setup.
    public static func bootstrap(options: LogLevelOption) async throws -> Initd {
        let log = makeLogger(label: "vminitd", level: options.resolvedLogLevel())
        try adjustLimits(log)

        // When running under debug mode, launch vminitd as a sub process of pid1
        // so that we get a chance to collect better logs and errors before pid1 exists
        // and the kernel panics.
        #if DEBUG
        log.info("DEBUG mode active, checking FOREGROUND env var")
        let environment = ProcessInfo.processInfo.environment
        let foreground = environment[foregroundEnvVar]
        log.info("checking for shim var \(foregroundEnvVar)=\(String(describing: foreground))")

        if foreground == nil {
            try runInForeground(log, logLevel: options.logLevel)
            _exit(0)
        }

        log.info("FOREGROUND is set, running as subprocess, setting subreaper")
        // Since we are not running as pid1 in this mode we must set ourselves
        // as a subreaper so that all child processes are reaped by us and not
        // passed onto our parent.
        CZ_set_sub_reaper()
        #endif

        signal(SIGPIPE, SIG_IGN)

        let gitCommit = String(cString: CZ_get_git_commit())
        let gitTag = String(cString: CZ_get_git_tag())
        let buildTime = String(cString: CZ_get_build_time())
        var metadata: Logger.Metadata = ["commit": "\(gitCommit)", "built": "\(buildTime)"]
        if !gitTag.isEmpty {
            metadata["tag"] = "\(gitTag)"
        }
        log.info("vminitd booting", metadata: metadata)

        // Set of mounts necessary to be mounted prior to taking any RPCs.
        // 1. /proc as the sysctl rpc wouldn't make sense if it wasn't there (NOTE: This is done before this method
        // due to Swift seemingly requiring /proc to be present for the async runtime to spin up).
        // 2. /run as that is where we store container state.
        // 3. /sys as we need it for /sys/fs/cgroup
        // 4. /sys/fs/cgroup to add the agent to a cgroup, as well as containers later.
        let mounts = [
            ContainerizationOS.Mount(
                type: "tmpfs",
                source: "tmpfs",
                target: "/run",
                options: []
            ),
            ContainerizationOS.Mount(
                type: "sysfs",
                source: "sysfs",
                target: "/sys",
                options: []
            ),
            ContainerizationOS.Mount(
                type: "cgroup2",
                source: "none",
                target: "/sys/fs/cgroup",
                options: []
            ),
        ]

        for mnt in mounts {
            log.info("mounting \(mnt.target)")

            try mnt.mount(createWithPerms: 0o755)
        }
        try Binfmt.mount()

        let cgManager = Cgroup2Manager(
            group: URL(filePath: "/vminitd"),
            logger: log
        )
        try cgManager.create()
        try cgManager.toggleAllAvailableControllers(enable: true)

        // Set memory.high threshold to 80 MiB
        let high: UInt64 = 80 * 1024 * 1024
        // Set memory.low to 50 MiB to avoid reclaiming vminitd's memory
        let low: UInt64 = 50 * 1024 * 1024

        try cgManager.setMemoryHigh(bytes: high)
        try cgManager.setMemoryLow(bytes: low)
        try cgManager.addProcess(pid: getpid())

        let memoryMonitor = try MemoryMonitor(
            cgroupManager: cgManager,
            threshold: high,
            logger: log
        ) { [log] (currentUsage, highMark) in
            log.warning(
                "vminitd memory threshold exceeded",
                metadata: [
                    "threshold_bytes": "\(high)",
                    "current_bytes": "\(currentUsage)",
                    "high_events_total": "\(highMark)",
                ])
        }

        let t = Thread { [log] in
            do {
                try memoryMonitor.run()
            } catch {
                log.error("memory monitor failed: \(error)")
            }
        }
        t.start()

        let eg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let blockingPool = NIOThreadPool(numberOfThreads: 2)
        blockingPool.start()
        return Initd(log: log, group: eg, blockingPool: blockingPool)
    }

    public mutating func run() async throws {
        let server = try await Self.bootstrap(options: options)

        do {
            server.log.info("serving vminitd API")
            try await server.serve(port: Self.vsockPort)
            server.log.info("vminitd API returned, syncing filesystems")

            #if os(Linux)
            sync()
            #endif
        } catch {
            server.log.error("vminitd boot error \(error)")

            #if os(Linux)
            sync()
            #endif

            _exit(1)
        }
    }

    private static func runInForeground(_ log: Logger, logLevel: String) throws {
        log.info("running vminitd under pid1")

        var command = Command("/sbin/vminitd", arguments: ["agent", "--log-level", logLevel])
        command.attrs = .init(setsid: true)
        command.stdin = .standardInput
        command.stdout = .standardOutput
        command.stderr = .standardError
        command.environment = ["\(foregroundEnvVar)=1"]

        try command.start()
        let exitCode = try command.wait()
        log.info("child process exited with code: \(exitCode)")
    }

    private static func adjustLimits(_ log: Logger) throws {
        let nrOpen = try String(contentsOfFile: "/proc/sys/fs/nr_open", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let max = UInt64(nrOpen) else {
            throw POSIXError(.EINVAL)
        }
        log.debug("setting RLIMIT_NOFILE to \(max)")
        guard CZ_setrlimit(CZ_RLIMIT_NOFILE, max, max) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }
}
