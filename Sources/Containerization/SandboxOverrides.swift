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
import Foundation

/// Per-component opt-ins to weaken the upstream-secure spawn flags for
/// cloud-hypervisor and virtiofsd. Each flag is independent so an operator
/// can target the minimum hardening that needs to come off — e.g. running
/// inside apple/container's `--virtualization` dev container needs both,
/// but a future bare-metal Linux host with a custom seccomp policy might
/// only need one.
///
/// Read once per process at first reference. Default false (secure).
///
/// **Legacy alias.** `CONTAINERIZATION_RELAXED_SANDBOX=1` continues to flip
/// every flag here for back-compat with the original combined toggle. New
/// callers should prefer the per-component vars below.
enum SandboxOverrides {
    /// When set, cloud-hypervisor is launched with `--seccomp false`.
    /// Disables CH's userspace seccomp BPF filter; the kernel's filter
    /// (whatever the host policy is) still applies.
    ///
    /// Env: `CONTAINERIZATION_NO_CH_SECCOMP=1`
    static let chSeccompDisabled: Bool =
        boolEnv("CONTAINERIZATION_NO_CH_SECCOMP") || legacyRelaxedSandbox

    /// When set, virtiofsd is launched with `--sandbox none`. Disables
    /// virtiofsd's userns + pivot_root + seccomp setup. Combined with the
    /// vendored cap-drop patch (`scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch`)
    /// at build time, the daemon retains its parent's capabilities — so
    /// only enable this when the parent process is the trust boundary you
    /// want.
    ///
    /// Env: `CONTAINERIZATION_NO_VIRTIOFSD_SANDBOX=1`
    static let virtiofsdSandboxDisabled: Bool =
        boolEnv("CONTAINERIZATION_NO_VIRTIOFSD_SANDBOX") || legacyRelaxedSandbox

    /// True if any override is currently in effect — used by callers that
    /// want to log a single banner regardless of which flag is set.
    static var anyEnabled: Bool {
        chSeccompDisabled || virtiofsdSandboxDisabled
    }

    /// Back-compat alias: enables every per-component flag in one shot.
    private static let legacyRelaxedSandbox: Bool =
        boolEnv("CONTAINERIZATION_RELAXED_SANDBOX")

    private static func boolEnv(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
    }
}

/// Minimal environment allowlist for child processes we spawn (`CHProcess`,
/// `VirtiofsdProcess`). Inheriting the parent's full env exposes any
/// secrets the calling tool happens to have set (`AWS_*`, `KUBE_*`,
/// `*_TOKEN`, etc.) to a binary that has no use for them. Only the
/// variables below are forwarded — extend this list when a new spawn-time
/// dependency surfaces, and document why.
///
/// - `PATH`, `HOME`: minimum POSIX hygiene; some libc/setuid paths look at
///   these even for self-contained binaries.
/// - `RUST_LOG`, `RUST_BACKTRACE`: cloud-hypervisor and virtiofsd are Rust
///   binaries; pass these through if the operator has set them so
///   debugging is unimpaired.
enum ChildEnvironment {
    /// Construct a minimal environment for the child as `KEY=value` strings
    /// suitable for `Command.environment`. Variables not present in the
    /// parent env are simply omitted.
    static func minimal() -> [String] {
        let allowlist = ["PATH", "HOME", "RUST_LOG", "RUST_BACKTRACE"]
        let parent = ProcessInfo.processInfo.environment
        var entries: [String] = []
        // PATH falls back to a sane default since Command's execve needs an
        // absolute path anyway, but child Rust binaries occasionally probe
        // PATH for helper tools.
        let path = parent["PATH"] ?? "/usr/sbin:/usr/bin:/sbin:/bin"
        entries.append("PATH=\(path)")
        for key in allowlist where key != "PATH" {
            if let value = parent[key] {
                entries.append("\(key)=\(value)")
            }
        }
        return entries
    }
}
#endif
