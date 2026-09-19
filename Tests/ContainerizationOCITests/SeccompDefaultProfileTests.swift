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

import ContainerizationError
import Crypto
import Foundation
import Testing

@testable import ContainerizationOCI

/// Tests for the containerd-derived default seccomp profile.
///
/// These assert shape and invariants — the default action, capability gating,
/// architecture handling and argument filters — rather than a golden transcript
/// of the ~360 allowed names, which would fail on every upstream resync.
/// ``baseAllowlistIsPinned()`` is the exception: shape testing cannot see a
/// name *added* to the list, so its size and digest are pinned.
struct SeccompDefaultProfileTests {
    /// Every syscall name the profile allows, from any rule.
    private func allowed(_ profile: LinuxSeccomp) -> Set<String> {
        Set(
            profile.syscalls
                .filter { $0.action == .actAllow }
                .flatMap(\.names)
        )
    }

    private func caps(bounding: [String]) -> ContainerizationOCI.LinuxCapabilities {
        .init(bounding: bounding, effective: bounding, permitted: bounding)
    }

    /// The restricted baseline runc and containerd use, and this repo's default.
    private static let defaultOCIBounding = [
        "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FSETID", "CAP_FOWNER", "CAP_MKNOD",
        "CAP_NET_RAW", "CAP_SETGID", "CAP_SETUID", "CAP_SETFCAP", "CAP_SETPCAP",
        "CAP_NET_BIND_SERVICE", "CAP_SYS_CHROOT", "CAP_KILL", "CAP_AUDIT_WRITE",
    ]

    @Test func defaultActionIsErrno() {
        let profile = LinuxSeccomp.defaultProfile(capabilities: nil, arch: .archAARCH64)
        #expect(profile.defaultAction == .actErrno)
        // Upstream leaves defaultErrnoRet unset, which means EPERM.
        #expect(profile.defaultErrnoRet == nil)
        #expect(profile.flags.isEmpty)
        #expect(!profile.syscalls.isEmpty)
    }

    /// The size and contents of the unconditional allowlist, pinned. The digest
    /// is over the names sorted and joined with newlines, reproducible from the
    /// reference:
    ///
    /// ```
    /// python3 -c 'import re,hashlib;
    ///   b=open("contrib/seccomp/seccomp_default.go").read();
    ///   i=b.index("Names: []string{"); j=b.index("\n\t\t\t\t},", i);
    ///   n=re.findall(r"^\s+\"([^\"]+)\",", b[i:j], re.M);
    ///   print(len(n), hashlib.sha256("\n".join(sorted(n)).encode()).hexdigest())'
    /// ```
    ///
    /// A failure means the allowlist changed: re-derive both values from the
    /// containerd revision being tracked and update them alongside the list.
    @Test func baseAllowlistIsPinned() {
        let profile = LinuxSeccomp.defaultProfile(capabilities: nil, arch: .archAARCH64)
        // The unconditional allowlist is upstream's first entry, and this port
        // keeps that ordering.
        guard let base = profile.syscalls.first else {
            Issue.record("the profile has no syscall rules at all")
            return
        }
        #expect(base.action == .actAllow)
        #expect(base.args.isEmpty)
        #expect(base.names.count == 363)
        // No duplicates: upstream has none, and a duplicate would make the
        // count agree with a list that is one name short.
        #expect(Set(base.names).count == base.names.count)

        let digest = SHA256.hash(data: Data(base.names.sorted().joined(separator: "\n").utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "768c34f9038ba519c4a1520dc38d3a7c2d07c4569f948408c0cf4293d4644738")
    }

    @Test func allowsOrdinaryWorkloadSyscalls() {
        let profile = LinuxSeccomp.defaultProfile(
            capabilities: caps(bounding: Self.defaultOCIBounding),
            arch: .archAARCH64
        )
        let names = allowed(profile)

        // A representative sample across the base allowlist: process, memory,
        // file, socket, signal, futex and time syscalls a normal container needs.
        for name in [
            "read", "write", "openat", "close", "execve", "exit_group", "wait4",
            "mmap", "mprotect", "munmap", "brk", "futex", "clock_gettime",
            "connect", "bind", "listen", "accept4", "sendto", "recvfrom",
            "rt_sigaction", "rt_sigreturn", "prctl", "getpid", "getuid",
            "statx", "fstat", "getdents64", "epoll_wait", "pipe2", "fork",
            "vfork", "capset", "chdir", "uname",
        ] {
            #expect(names.contains(name), "expected the profile to allow \(name)")
        }
    }

    @Test func blocksDangerousSyscalls() {
        // With the default capability baseline, none of these has a gate that
        // would unlock it.
        let profile = LinuxSeccomp.defaultProfile(
            capabilities: caps(bounding: Self.defaultOCIBounding),
            arch: .archAARCH64
        )
        let names = allowed(profile)

        for name in [
            // Keyring: unnamespaced, so a container can reach the host keyring.
            "keyctl", "add_key", "request_key",
            // Lets a process handle its own page faults; a long-running source
            // of kernel-exploit primitives.
            "userfaultfd",
            // Gated on CAP_SYS_ADMIN / CAP_BPF, absent here.
            "bpf",
            // Gated on CAP_SYS_MODULE, absent here.
            "init_module", "finit_module", "delete_module",
            // Gated on CAP_SYS_ADMIN, absent here.
            "mount", "umount2", "setns", "unshare",
            // Also gated, each on a capability the baseline lacks:
            // open_by_handle_at on CAP_DAC_READ_SEARCH, fanotify_init on
            // CAP_SYS_ADMIN, syslog on CAP_SYS_ADMIN or CAP_SYSLOG,
            // perf_event_open on CAP_SYS_ADMIN or CAP_PERFMON.
            "open_by_handle_at", "fanotify_init", "syslog", "perf_event_open",
            // Gated on CAP_SYS_BOOT / CAP_SYS_PACCT / CAP_SYS_RAWIO / CAP_SYS_TIME.
            "reboot", "acct", "iopl", "ioperm", "settimeofday",
            // In no upstream group at all, like the keyring and userfaultfd
            // entries above: no capability unlocks these.
            "kexec_load", "kexec_file_load", "swapon", "swapoff", "pivot_root",
        ] {
            #expect(!names.contains(name), "expected the profile to block \(name)")
        }
    }

    /// The one deliberate deviation from upstream's rule set: containerd gates
    /// the ptrace group on the running kernel being >= 4.8, and this port
    /// includes it unconditionally because the profile is built on a host whose
    /// kernel is not the one it will be installed on.
    @Test func ptraceGroupIsPresentWithoutCapabilities() {
        for capabilities in [nil, caps(bounding: Self.defaultOCIBounding)] {
            let names = allowed(
                LinuxSeccomp.defaultProfile(capabilities: capabilities, arch: .archAARCH64)
            )
            // Exactly the three names in upstream's kernel-version group.
            for name in ["process_vm_readv", "process_vm_writev", "ptrace"] {
                #expect(names.contains(name), "the kernel-version group should be included unconditionally: \(name)")
            }
            // The rest of the CAP_SYS_PTRACE group is still gated, so this is
            // the kernel-version group and not a capability leak.
            for name in ["kcmp", "pidfd_getfd", "process_madvise"] {
                #expect(!names.contains(name), "\(name) needs CAP_SYS_PTRACE")
            }
        }
    }

    @Test func capSysAdminUnlocksItsGroup() {
        let without = allowed(
            LinuxSeccomp.defaultProfile(
                capabilities: caps(bounding: Self.defaultOCIBounding),
                arch: .archAARCH64
            ))
        let with = allowed(
            LinuxSeccomp.defaultProfile(
                capabilities: caps(bounding: Self.defaultOCIBounding + ["CAP_SYS_ADMIN"]),
                arch: .archAARCH64
            ))

        // The full group containerd unlocks for CAP_SYS_ADMIN.
        let group = [
            "bpf", "clone", "clone3", "fanotify_init", "fsconfig", "fsmount",
            "fsopen", "fspick", "lookup_dcookie", "mount", "mount_setattr",
            "move_mount", "open_tree", "perf_event_open", "quotactl",
            "quotactl_fd", "setdomainname", "sethostname", "setns", "syslog",
            "umount", "umount2", "unshare",
        ]
        for name in group {
            #expect(with.contains(name), "CAP_SYS_ADMIN should unlock \(name)")
        }
        // `clone` is allowed either way, but only under an argument filter when
        // CAP_SYS_ADMIN is absent — see cloneIsFilteredWithoutSysAdmin.
        for name in group where name != "clone" {
            #expect(!without.contains(name), "\(name) should need CAP_SYS_ADMIN")
        }
    }

    @Test func otherCapabilitiesUnlockTheirGroups() {
        // capability -> a syscall that only that capability's group allows.
        let cases: [(String, [String])] = [
            ("CAP_DAC_READ_SEARCH", ["open_by_handle_at"]),
            ("CAP_SYS_BOOT", ["reboot"]),
            ("CAP_SYS_CHROOT", ["chroot"]),
            ("CAP_SYS_MODULE", ["delete_module", "init_module", "finit_module"]),
            ("CAP_SYS_PACCT", ["acct"]),
            ("CAP_SYS_PTRACE", ["kcmp", "pidfd_getfd", "process_madvise"]),
            ("CAP_SYS_RAWIO", ["iopl", "ioperm"]),
            ("CAP_SYS_TIME", ["settimeofday", "stime", "clock_settime", "clock_settime64"]),
            ("CAP_SYS_TTY_CONFIG", ["vhangup"]),
            ("CAP_SYS_NICE", ["get_mempolicy", "mbind", "set_mempolicy", "set_mempolicy_home_node"]),
            ("CAP_SYSLOG", ["syslog"]),
            ("CAP_BPF", ["bpf"]),
            ("CAP_PERFMON", ["perf_event_open"]),
        ]

        for (capability, syscalls) in cases {
            // CAP_SYS_CHROOT is in the default baseline, so the comparison has
            // to be against a set that excludes the capability under test.
            let without = Self.defaultOCIBounding.filter { $0 != capability }
            let baseline = allowed(
                LinuxSeccomp.defaultProfile(
                    capabilities: caps(bounding: without),
                    arch: .archAARCH64
                ))
            let granted = allowed(
                LinuxSeccomp.defaultProfile(
                    capabilities: caps(bounding: without + [capability]),
                    arch: .archAARCH64
                ))
            for syscall in syscalls {
                #expect(granted.contains(syscall), "\(capability) should unlock \(syscall)")
                #expect(!baseline.contains(syscall), "\(syscall) should need \(capability)")
            }
        }
    }

    @Test func gatingReadsTheBoundingSetOnly() {
        // containerd inspects Process.Capabilities.Bounding. A capability that
        // is effective/permitted but not bounding cannot actually be used, and
        // must not widen the filter.
        let profile = LinuxSeccomp.defaultProfile(
            capabilities: .init(
                bounding: Self.defaultOCIBounding,
                effective: Self.defaultOCIBounding + ["CAP_SYS_ADMIN"],
                permitted: Self.defaultOCIBounding + ["CAP_SYS_ADMIN"],
                ambient: ["CAP_SYS_ADMIN"]
            ),
            arch: .archAARCH64
        )
        #expect(!allowed(profile).contains("mount"))
    }

    @Test func cloneIsFilteredWithoutSysAdmin() {
        let profile = LinuxSeccomp.defaultProfile(
            capabilities: caps(bounding: Self.defaultOCIBounding),
            arch: .archAARCH64
        )

        let cloneRules = profile.syscalls.filter { $0.names.contains("clone") }
        #expect(cloneRules.count == 1)
        guard let clone = cloneRules.first, let arg = clone.args.first else {
            Issue.record("expected exactly one clone rule with an argument filter")
            return
        }
        #expect(clone.action == .actAllow)
        #expect(clone.args.count == 1)
        // Masked-equal against the namespace flags with an expected value of 0:
        // clone is allowed only when it creates no new namespace. arg0 on every
        // architecture except s390.
        #expect(arg.index == 0)
        #expect(arg.op == .opMaskedEqual)
        #expect(arg.value == 0x7E02_0000)
        #expect(arg.valueTwo == 0)

        // clone3 gets ENOSYS rather than the default EPERM, so that glibc falls
        // back to clone instead of treating the container as broken.
        let clone3Rules = profile.syscalls.filter { $0.names.contains("clone3") }
        #expect(clone3Rules.count == 1)
        #expect(clone3Rules.first?.action == .actErrno)
        #expect(clone3Rules.first?.errnoRet == 38)  // ENOSYS
    }

    @Test func clone3EnosysFollowsTheArchitecture() {
        // Upstream hardcodes 38 and is right by construction: containerd builds
        // one binary per GOARCH. Here the architecture is a parameter, and
        // errno numbering is not uniform — MIPS and PA-RISC renumber it.
        func clone3Errno(_ arch: Arch) -> UInt? {
            LinuxSeccomp.defaultProfile(capabilities: nil, arch: arch)
                .syscalls
                .first { $0.names.contains("clone3") && $0.action == .actErrno }?
                .errnoRet
        }
        #expect(clone3Errno(.archAARCH64) == 38)
        #expect(clone3Errno(.archX86_64) == 38)
        #expect(clone3Errno(.archMIPS64) == 89)
        #expect(clone3Errno(.archMIPSEL) == 89)
        #expect(clone3Errno(.archPARISC) == 251)
        #expect(clone3Errno(.archPARISC64) == 251)
    }

    @Test func cloneIsUnfilteredWithSysAdmin() {
        let profile = LinuxSeccomp.defaultProfile(
            capabilities: caps(bounding: ["CAP_SYS_ADMIN"]),
            arch: .archAARCH64
        )
        let cloneRules = profile.syscalls.filter { $0.names.contains("clone") }
        #expect(cloneRules.count == 1)
        #expect(cloneRules.first?.args.isEmpty == true)
        // No ENOSYS override for clone3: it is plainly allowed.
        #expect(profile.syscalls.contains(where: { $0.action == .actErrno }) == false)
    }

    @Test func s390PutsTheCloneFlagsInArgOne() {
        // s390 swaps clone(2)'s first two arguments.
        let profile = LinuxSeccomp.defaultProfile(
            capabilities: caps(bounding: []),
            arch: .archS390X
        )
        let clone = profile.syscalls.first { $0.names.contains("clone") && !$0.args.isEmpty }
        #expect(clone?.args.first?.index == 1)
    }

    @Test func architecturesForAarch64() {
        let profile = LinuxSeccomp.defaultProfile(capabilities: nil, arch: .archAARCH64)
        // 32-bit arm is included so an armhf binary in an arm64 container is
        // filtered rather than running with no filter at all.
        #expect(profile.architectures == [.archARM, .archAARCH64])
    }

    @Test func architecturesForX86_64() {
        let profile = LinuxSeccomp.defaultProfile(capabilities: nil, arch: .archX86_64)
        #expect(profile.architectures == [.archX86_64, .archX86, .archX32])
    }

    @Test func archSpecificSyscallGroups() {
        let arm = allowed(LinuxSeccomp.defaultProfile(capabilities: nil, arch: .archAARCH64))
        let amd = allowed(LinuxSeccomp.defaultProfile(capabilities: nil, arch: .archX86_64))

        for name in ["arm_fadvise64_64", "arm_sync_file_range", "sync_file_range2", "breakpoint", "cacheflush", "set_tls"] {
            #expect(arm.contains(name), "arm64 profile should allow \(name)")
            #expect(!amd.contains(name), "x86_64 profile should not allow \(name)")
        }
        for name in ["arch_prctl", "modify_ldt"] {
            #expect(amd.contains(name), "x86_64 profile should allow \(name)")
            #expect(!arm.contains(name), "arm64 profile should not allow \(name)")
        }
    }

    @Test func socketFiltersLeaveVsockAndAlgUnreachable() {
        let profile = LinuxSeccomp.defaultProfile(capabilities: nil, arch: .archAARCH64)
        let socketRules = profile.syscalls.filter { $0.names.contains("socket") }

        // Three rules, each with exactly one condition: collapsing them into
        // one makes the conditions behave as OR.
        #expect(socketRules.count == 3)
        for rule in socketRules {
            #expect(rule.names == ["socket"])
            #expect(rule.action == .actAllow)
            #expect(rule.args.count == 1, "a socket rule with several conditions behaves as OR")
        }

        // AF_ALG == 38, AF_VSOCK == 40: allowed are < 38, == 39, > 40, so 38 and
        // 40 match nothing and fall through to the default errno action.
        let conditions = socketRules.compactMap(\.args.first).map { ($0.index, $0.op, $0.value) }
        #expect(conditions.allSatisfy { $0.0 == 0 })
        #expect(conditions.contains { $0.1 == .opLessThan && $0.2 == 38 })
        #expect(conditions.contains { $0.1 == .opEqualTo && $0.2 == 39 })
        #expect(conditions.contains { $0.1 == .opGreaterThan && $0.2 == 40 })
    }

    @Test func personalityIsRestrictedToKnownDomains() {
        let profile = LinuxSeccomp.defaultProfile(capabilities: nil, arch: .archAARCH64)
        let rules = profile.syscalls.filter { $0.names.contains("personality") }
        #expect(rules.count == 5)
        let values = Set(rules.compactMap(\.args.first).map(\.value))
        #expect(values == [0x0, 0x0008, 0x0002_0000, 0x0002_0008, 0xFFFF_FFFF])
    }

    /// The host sends the runtime spec to the guest as JSON in the
    /// `configuration` field, and vminitd re-encodes the decoded `Spec` into the
    /// runc bundle's config.json. `Linux` has a hand-written `init(from:)`, so a
    /// new field can be silently dropped in transit; this pins the round trip.
    @Test func seccompSurvivesSpecJSONRoundTrip() throws {
        let profile = LinuxSeccomp.defaultProfile(
            capabilities: caps(bounding: Self.defaultOCIBounding),
            arch: .archAARCH64
        )
        let spec = Spec(
            version: "1.2.0",
            process: ContainerizationOCI.Process(args: ["/bin/true"], cwd: "/"),
            linux: Linux(seccomp: profile)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(spec)

        let decoded = try JSONDecoder().decode(Spec.self, from: first)
        guard let roundTripped = decoded.linux?.seccomp else {
            Issue.record("seccomp was dropped decoding the spec")
            return
        }
        #expect(roundTripped.defaultAction == .actErrno)
        #expect(roundTripped.architectures == profile.architectures)
        #expect(roundTripped.syscalls.count == profile.syscalls.count)
        #expect(allowed(roundTripped) == allowed(profile))
        // The one rule carrying an errnoRet; a dropped optional would read as
        // EPERM in the guest instead of ENOSYS.
        #expect(roundTripped.syscalls.first { $0.names.contains("clone3") }?.errnoRet == 38)

        // Re-encoding is byte-identical, which is what vminitd writes to
        // config.json for runc to read.
        let second = try encoder.encode(decoded)
        #expect(first == second)

        // Spelled with the runtime-spec's own key and value names, since runc is
        // the consumer.
        let json = String(decoding: first, as: UTF8.self)
        #expect(json.contains("\"defaultAction\":\"SCMP_ACT_ERRNO\""))
        #expect(json.contains("\"SCMP_ARCH_AARCH64\""))
        #expect(json.contains("\"SCMP_CMP_MASKED_EQ\""))
    }

    @Test func archCurrentMatchesTheBuildArchitecture() {
        #if arch(arm64)
        #expect(Arch.current == .archAARCH64)
        #elseif arch(x86_64)
        #expect(Arch.current == .archX86_64)
        #else
        #expect(Arch.current == nil)
        #endif
    }

    /// `Arch.current` is a compile-time constant while the profile is installed
    /// on a guest running the host's architecture. Pins the cross-check that
    /// the two agree.
    @Test func currentVerifiedAgreesWithTheRunningMachine() throws {
        #if arch(arm64)
        #expect(Platform.current.architecture == "arm64")
        #expect(try Arch.currentVerified() == .archAARCH64)
        #elseif arch(x86_64)
        #expect(Platform.current.architecture == "amd64")
        #expect(try Arch.currentVerified() == .archX86_64)
        #else
        // Arch cannot name this architecture, so there is no profile to build.
        #expect(throws: ContainerizationError.self) { try Arch.currentVerified() }
        #endif
    }
}
