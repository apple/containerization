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

/// NOTE: This binary implements a very small subset of the OCI runtime spec, mostly just
/// the process configurations. Mounts are somewhat functional, but masked and read only paths
/// aren't checked today. Today the namespaces are also ignored, and we always spawn a new pid
/// and mount namespace.

import ArgumentParser
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import LCShim
import Logging
import Musl

@main
struct App: ParsableCommand {
    static let ackPid = "AckPid"
    static let ackConsole = "AckConsole"

    static let configuration = CommandConfiguration(
        commandName: "vmexec",
        version: "0.1.0",
        subcommands: [
            ExecCommand.self,
            RunCommand.self,
        ]
    )
}

extension App {
    /// Applies O_CLOEXEC to all file descriptors currently open for
    /// the process except the stdio fd values
    static func applyCloseExecOnFDs() throws {
        let minFD = 2  // stdin, stdout, stderr should be preserved

        let fdList = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")

        for fdStr in fdList {
            guard let fd = Int(fdStr) else {
                continue
            }
            if fd <= minFD {
                continue
            }

            _ = fcntl(Int32(fd), F_SETFD, FD_CLOEXEC)
        }
    }

    static func exec(process: ContainerizationOCI.Process, currentEnv: [String]? = nil) throws {
        guard !process.args.isEmpty else {
            throw App.Errno(stage: "exec", info: "process args cannot be empty")
        }

        // lookup executable
        let path = Path.findPath(currentEnv) ?? Path.getCurrentPath()
        guard let resolvedExecutable = Path.lookPath(process.args[0], path: path) else {
            throw App.Failure(message: "failed to find target executable \(process.args[0])")
        }

        let executable = strdup(resolvedExecutable.path())
        var argv = process.args.map { strdup($0) }
        argv += [nil]

        let env = process.env.map { strdup($0) } + [nil]
        let cwd = process.cwd

        // switch cwd
        guard chdir(cwd) == 0 else {
            throw App.Errno(stage: "chdir(cwd)", info: "failed to change directory to '\(cwd)'")
        }

        guard execvpe(executable, argv, env) != -1 else {
            throw App.Errno(stage: "execvpe(\(String(describing: executable)))", info: "failed to exec [\(process.args.joined(separator: " "))]")
        }
        fatalError("execvpe failed")
    }

    static func setPermissions(user: ContainerizationOCI.User) throws {
        if user.additionalGids.count > 0 {
            guard setgroups(user.additionalGids.count, user.additionalGids) == 0 else {
                throw App.Errno(stage: "setgroups()")
            }
        }
        guard setgid(user.gid) == 0 else {
            throw App.Errno(stage: "setgid()")
        }
        // NOTE: setuid has to be done last because once the uid has been
        // changed, then the process will lose privilege to set the group
        // and supplementary groups
        guard setuid(user.uid) == 0 else {
            throw App.Errno(stage: "setuid()")
        }
    }

    static func fixStdioPerms(user: ContainerizationOCI.User) throws {
        for i in 0...2 {
            var fdStat = stat()
            try withUnsafeMutablePointer(to: &fdStat) { pointer in
                guard fstat(Int32(i), pointer) == 0 else {
                    throw App.Errno(stage: "fstat(fd)")
                }
            }

            let desired = uid_t(user.uid)
            if fdStat.st_uid != desired {
                guard fchown(Int32(i), desired, fdStat.st_gid) != -1 else {
                    throw App.Errno(stage: "fchown(\(i))")
                }
            }
        }
    }

    static func setRLimits(rlimits: [ContainerizationOCI.POSIXRlimit]) throws {
        for rl in rlimits {
            var limit = rlimit(rlim_cur: rl.soft, rlim_max: rl.hard)
            let resource: Int32
            switch rl.type {
            case "RLIMIT_AS":
                resource = RLIMIT_AS
            case "RLIMIT_CORE":
                resource = RLIMIT_CORE
            case "RLIMIT_CPU":
                resource = RLIMIT_CPU
            case "RLIMIT_DATA":
                resource = RLIMIT_DATA
            case "RLIMIT_FSIZE":
                resource = RLIMIT_FSIZE
            case "RLIMIT_NOFILE":
                resource = RLIMIT_NOFILE
            case "RLIMIT_STACK":
                resource = RLIMIT_STACK
            case "RLIMIT_NPROC":
                resource = RLIMIT_NPROC
            case "RLIMIT_RSS":
                resource = RLIMIT_RSS
            case "RLIMIT_MEMLOCK":
                resource = RLIMIT_MEMLOCK
            default:
                errno = EINVAL
                throw App.Errno(stage: "rlimit key unknown")
            }
            guard setrlimit(resource, &limit) == 0 else {
                throw App.Errno(stage: "setrlimit()")
            }
        }
    }

    static func prepareCapabilities(capabilities: ContainerizationOCI.LinuxCapabilities) throws -> ContainerizationOS.LinuxCapabilities? {
        // Create capabilities instance from OCI config
        var caps = ContainerizationOS.LinuxCapabilities()

        caps.set(which: [.effective], caps: (capabilities.effective ?? []).compactMap { CapabilityName(rawValue: $0) })
        caps.set(which: [.permitted], caps: (capabilities.permitted ?? []).compactMap { CapabilityName(rawValue: $0) })
        caps.set(which: [.inheritable], caps: (capabilities.inheritable ?? []).compactMap { CapabilityName(rawValue: $0) })
        caps.set(which: [.bounding], caps: (capabilities.bounding ?? []).compactMap { CapabilityName(rawValue: $0) })
        caps.set(which: [.ambient], caps: (capabilities.ambient ?? []).compactMap { CapabilityName(rawValue: $0) })

        // Apply bounding set BEFORE user change (drop capabilities early)
        do {
            try caps.apply(kind: .bounds)
        } catch {
            throw App.Failure(message: "failed to apply bounding set capabilities: \(error)")
        }

        // Set keep caps to preserve capabilities across setuid()
        do {
            try LinuxCapabilities.setKeepCaps()
        } catch {
            throw App.Failure(message: "failed to set keep caps: \(error)")
        }

        return caps
    }

    static func finishCapabilities(_ caps: ContainerizationOS.LinuxCapabilities?) throws {
        guard let caps = caps else { return }

        do {
            try LinuxCapabilities.clearKeepCaps()
        } catch {
            throw App.Failure(message: "failed to clear keep caps: \(error)")
        }

        do {
            try caps.apply(kind: [.caps])
        } catch {
            throw App.Failure(message: "failed to apply final capabilities: \(error)")
        }

        try? caps.apply(kind: [.ambs])
    }

    static func Errno(stage: String, info: String = "") -> ContainerizationError {
        let posix = POSIXError(.init(rawValue: errno)!, userInfo: ["stage": stage])
        return ContainerizationError(.internalError, message: "\(info) \(String(describing: posix))")
    }

    static func Failure(message: String) -> ContainerizationError {
        ContainerizationError(
            .internalError,
            message: message
        )
    }

    static func writeError(_ error: Error) {
        let errorPipe = FileHandle(fileDescriptor: 5)

        let errorMessage: String
        if let czError = error as? ContainerizationError {
            errorMessage = czError.description
        } else {
            errorMessage = String(describing: error)
        }

        if let data = errorMessage.data(using: .utf8) {
            try? errorPipe.write(contentsOf: data)
        }
        try? errorPipe.close()
    }
}
