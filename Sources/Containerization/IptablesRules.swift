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
import ContainerizationError
import ContainerizationOS
import Foundation

/// Thin idempotent wrappers around the `iptables` CLI for use by
/// `BridgeManager`. We don't program nftables directly; modern distros
/// ship the `iptables` binary as a shim over nftables and it's universally
/// available.
enum IptablesRules {
    /// Add a rule unless it already exists. `args` is the rule body
    /// excluding the leading action (`-A`/`-C`/`-D`).
    ///
    /// Implementation: run `iptables -C <args>` first; if exit 0, the rule
    /// exists already — return. Otherwise run `iptables -A <args>` and
    /// throw on non-zero exit.
    static func ensure(table: String? = nil, args: [String]) throws {
        let tableArgs = table.map { ["-t", $0] } ?? []
        let check = try run(args: tableArgs + ["-C"] + args)
        if check.exit == 0 { return }
        let add = try run(args: tableArgs + ["-A"] + args)
        if add.exit != 0 {
            throw ContainerizationError(
                .internalError,
                message: """
                    iptables -A \(args.joined(separator: " ")) failed (exit \(add.exit))\
                    \(add.stderr.isEmpty ? "" : ": \(add.stderr)")
                    """
            )
        }
    }

    /// Best-effort delete. Ignores non-zero exit (rule may not exist).
    static func remove(table: String? = nil, args: [String]) {
        let tableArgs = table.map { ["-t", $0] } ?? []
        _ = try? run(args: tableArgs + ["-D"] + args)
    }

    /// Captured outcome of a single `iptables` invocation.
    private struct InvocationResult {
        let exit: Int32
        let stderr: String
    }

    /// Run `iptables` with the given args, returning the exit status and any
    /// stderr the binary emitted. Throws if no `iptables` binary is found.
    private static func run(args: [String]) throws -> InvocationResult {
        // ContainerizationOS.Command uses execve() under the hood, which
        // requires an absolute path. Probe the two paths iptables actually
        // ships at on Linux distros — /usr/sbin first (Debian, Ubuntu,
        // Fedora, Alpine, RHEL), then /sbin (older / busybox-style).
        let candidates = ["/usr/sbin/iptables", "/sbin/iptables"]
        // Open /dev/null fresh rather than using FileHandle.nullDevice:
        // swift-corelibs-foundation's nullDevice uses a sentinel fd that
        // doesn't survive dup2() in Command's child, producing EBADF on exec.
        // Capture stderr through a pipe so failures surface with the actual
        // iptables error (locked xtables, missing kernel module, conflicting
        // rule) instead of an opaque exit code.
        let devNullOut = FileHandle(forWritingAtPath: "/dev/null")
        let stderrPipe = Pipe()
        defer {
            try? devNullOut?.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            // `-w` makes iptables block on the xtables lock rather than
            // failing (exit 4) when another actor — a sibling BridgeManager on
            // a different bridge, Docker, firewalld — is mid-iptables. Accepted
            // by both legacy iptables and the nft shim.
            var cmd = Command(path, arguments: ["-w"] + args)
            cmd.stdout = devNullOut
            cmd.stderr = stderrPipe.fileHandleForWriting
            try cmd.start()
            // Close the parent's write end so the read end sees EOF when
            // iptables exits, even if iptables itself never writes anything.
            try? stderrPipe.fileHandleForWriting.close()
            let exit = try cmd.wait()
            let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr =
                String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return InvocationResult(exit: exit, stderr: stderr)
        }
        throw ContainerizationError(
            .notFound,
            message: "iptables not found at /usr/sbin/iptables or /sbin/iptables; install iptables (or its nftables shim)"
        )
    }
}
#endif
