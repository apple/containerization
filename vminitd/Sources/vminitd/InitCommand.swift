//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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

import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation
import LCShim
import Logging
import Musl
import NIOCore
import NIOPosix

struct InitCommand {
    private static let foregroundEnvVar = "FOREGROUND"
    private static let vsockPort = 1024

    static func run() async throws {
        var log = Logger(label: "vminitd")

        try Self.adjustLimits()

        // when running under debug mode, launch vminitd as a sub process of pid1
        // so that we get a chance to collect better logs and errors before pid1 exists
        // and the kernel panics.
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let foreground = environment[Self.foregroundEnvVar]
        log.info("checking for shim var \(Self.foregroundEnvVar)=\(String(describing: foreground))")

        if foreground == nil {
            try Self.runInForeground(log)
            Musl.exit(0)
        }

        // since we are not running as pid1 in this mode we must set ourselves
        // as a subpreaper so that all child processes are reaped by us and not
        // passed onto our parent.
        CZ_set_sub_reaper()
        #endif

        signal(SIGPIPE, SIG_IGN)

        // Because the sysctl rpc wouldn't make sense if this didn't always exist, we
        // ALWAYS mount /proc.
        guard Musl.mount("proc", "/proc", "proc", 0, "") == 0 else {
            log.error("failed to mount /proc")
            Musl.exit(1)
        }
        guard Musl.mount("tmpfs", "/run", "tmpfs", 0, "") == 0 else {
            log.error("failed to mount /run")
            Musl.exit(1)
        }
        try Binfmt.mount()

        log.logLevel = .debug

        log.info("vminitd booting")
        let eg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let server = Initd(log: log, group: eg)

        do {
            log.info("serving vminitd API")
            try await server.serve(port: Self.vsockPort)
            log.info("vminitd API returned, syncing filesystems")

            Musl.sync()
        } catch {
            log.error("vminitd boot error \(error)")

            Musl.sync()
            Musl.exit(1)
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
        _ = try command.wait()
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
