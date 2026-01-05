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

import Cgroup
import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import NIOCore
import NIOPosix

#if os(Linux)
import Musl
import LCShim
#endif

struct InitCommand {
    private static let foregroundEnvVar = "FOREGROUND"
    private static let vsockPort = 1024

    static func run(log: Logger) async throws {
        var log = log

        try Self.adjustLimits()

        // when running under debug mode, launch vminitd as a sub process of pid1
        // so that we get a chance to collect better logs and errors before pid1 exists
        // and the kernel panics.
        #if DEBUG
        log.info("DEBUG mode active, checking FOREGROUND env var")
        let environment = ProcessInfo.processInfo.environment
        let foreground = environment[Self.foregroundEnvVar]
        log.info("checking for shim var \(foregroundEnvVar)=\(String(describing: foreground))")

        if foreground == nil {
            try runInForeground(log)
            exit(0)
        }

        log.info("FOREGROUND is set, running as subprocess, setting subreaper")
        // since we are not running as pid1 in this mode we must set ourselves
        // as a subpreaper so that all child processes are reaped by us and not
        // passed onto our parent.
        CZ_set_sub_reaper()
        #endif

        log.logLevel = .debug

        signal(SIGPIPE, SIG_IGN)

        log.info("vminitd booting")

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

        // Set memory.high threshold to 75 MiB
        let threshold: UInt64 = 75 * 1024 * 1024
        try cgManager.setMemoryHigh(bytes: threshold)
        try cgManager.addProcess(pid: getpid())

        let memoryMonitor = try MemoryMonitor(
            cgroupManager: cgManager,
            threshold: threshold,
            logger: log
        ) { [log] (currentUsage, highMark) in
            log.warning(
                "vminitd memory threshold exceeded",
                metadata: [
                    "threshold_bytes": "\(threshold)",
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

        let eg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let server = Initd(log: log, group: eg)

        do {
            log.info("serving vminitd API")
            try await server.serve(port: vsockPort)
            log.info("vminitd API returned, syncing filesystems")

            #if os(Linux)
            Musl.sync()
            #endif
        } catch {
            log.error("vminitd boot error \(error)")

            #if os(Linux)
            Musl.sync()
            #endif

            exit(1)
        }
    }

    private static func runInForeground(_ log: Logger) throws {
        log.info("running vminitd under pid1")

        var command = Command("/sbin/vminitd")
        command.attrs = .init(setsid: true)
        command.stdin = .standardInput
        command.stdout = .standardOutput
        command.stderr = .standardError
        command.environment = ["\(foregroundEnvVar)=1"]

        try command.start()
        let exitCode = try command.wait()
        log.info("child process exited with code: \(exitCode)")
    }

    private static func adjustLimits() throws {
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
}
