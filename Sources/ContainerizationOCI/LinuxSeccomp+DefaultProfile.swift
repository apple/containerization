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

//  A port of containerd's `DefaultProfile`, from
//  `contrib/seccomp/seccomp_default.go` in github.com/containerd/containerd
//  (Apache-2.0, the same license as this repository). The lists are transcribed
//  verbatim so this file can be diffed against its upstream original — do not
//  reorder, dedupe or drop entries that look redundant.
//
//  Deviations from the Go, each noted again at its site below:
//
//  * The `process_vm_readv` / `process_vm_writev` / `ptrace` group is included
//    unconditionally; upstream gates it on the running kernel being >= 4.8,
//    below which ptrace is a seccomp bypass. Safe here only because the profile
//    is built on the host for a guest that must already support cgroup v2,
//    virtiofs and vsock — 5.x at the earliest. Restore the gate if a guest
//    kernel below 4.8 ever becomes bootable.
//  * The architecture is a parameter rather than `runtime.GOARCH`, because the
//    profile is built on a macOS host for a Linux guest.
//  * ``Arch`` has no LoongArch case, so upstream's `loong64` case has no
//    equivalent here.

import ContainerizationError

extension LinuxSeccomp {
    /// The default seccomp profile: a syscall allowlist with `SCMP_ACT_ERRNO`
    /// as the default action, ported from containerd's `DefaultProfile`.
    ///
    /// Not a constant: containerd unlocks extra syscall groups for particular
    /// capabilities and tightens `clone`/`clone3` when `CAP_SYS_ADMIN` is
    /// absent. Only a real OCI runtime applies seccomp — the `vmexec` launch
    /// path ignores `spec.linux.seccomp`.
    ///
    /// - Parameters:
    ///   - capabilities: The capabilities of the process the profile will be
    ///     applied to. Only ``LinuxCapabilities/bounding`` is consulted, which
    ///     is what containerd inspects. A `nil` value, or a `nil` bounding set,
    ///     is treated as "no capabilities" — the most restrictive profile.
    ///   - arch: The native architecture of the machine the profile will be
    ///     applied on (i.e. the guest architecture, not the host's). Selects
    ///     both the `architectures` list — generally wider than the single
    ///     value passed — and the architecture-specific syscall group.
    public static func defaultProfile(capabilities: LinuxCapabilities?, arch: Arch) -> LinuxSeccomp {
        var syscalls: [LinuxSyscall] = [
            LinuxSyscall(
                names: Self.defaultProfileBaseSyscalls,
                action: .actAllow,
                errnoRet: nil,
                args: []
            ),
            // Allow socket(2) for every address family except AF_VSOCK and AF_ALG:
            // three single-condition ranges that both fall outside of, so they hit
            // the default errno action. (On socketcall(2) ABIs socket() goes through
            // socketcall(2), allowed unconditionally above.)
            //
            // Keep them as three rules: runc splits repeated argument-index
            // conditions into separate libseccomp rules, which then behave as OR.
            //
            // Known weakness inherited from upstream: seccomp compares the full
            // 64-bit register while the kernel truncates the domain to an `int`,
            // so `0x1_0000_0026` matches the third rule but arrives as AF_ALG.
            LinuxSyscall(
                names: ["socket"],
                action: .actAllow,
                errnoRet: nil,
                args: [
                    LinuxSeccompArg(index: 0, value: Self.afALG, valueTwo: 0, op: .opLessThan)
                ]
            ),
            LinuxSyscall(
                names: ["socket"],
                action: .actAllow,
                errnoRet: nil,
                args: [
                    LinuxSeccompArg(index: 0, value: Self.afALG + 1, valueTwo: 0, op: .opEqualTo)
                ]
            ),
            LinuxSyscall(
                names: ["socket"],
                action: .actAllow,
                errnoRet: nil,
                args: [
                    LinuxSeccompArg(index: 0, value: Self.afVSOCK, valueTwo: 0, op: .opGreaterThan)
                ]
            ),
            LinuxSyscall(
                names: ["personality"],
                action: .actAllow,
                errnoRet: nil,
                args: [
                    LinuxSeccompArg(index: 0, value: 0x0, valueTwo: 0, op: .opEqualTo)
                ]
            ),
            LinuxSyscall(
                names: ["personality"],
                action: .actAllow,
                errnoRet: nil,
                args: [
                    LinuxSeccompArg(index: 0, value: 0x0008, valueTwo: 0, op: .opEqualTo)
                ]
            ),
            LinuxSyscall(
                names: ["personality"],
                action: .actAllow,
                errnoRet: nil,
                args: [
                    LinuxSeccompArg(index: 0, value: 0x0002_0000, valueTwo: 0, op: .opEqualTo)
                ]
            ),
            LinuxSyscall(
                names: ["personality"],
                action: .actAllow,
                errnoRet: nil,
                args: [
                    LinuxSeccompArg(index: 0, value: 0x0002_0008, valueTwo: 0, op: .opEqualTo)
                ]
            ),
            LinuxSyscall(
                names: ["personality"],
                action: .actAllow,
                errnoRet: nil,
                args: [
                    LinuxSeccompArg(index: 0, value: 0xFFFF_FFFF, valueTwo: 0, op: .opEqualTo)
                ]
            ),
        ]

        // "include by kernel version" upstream, gated on the running kernel
        // being >= 4.8. See the deviation note at the top of this file.
        syscalls.append(
            LinuxSyscall(
                names: [
                    "process_vm_readv",
                    "process_vm_writev",
                    "ptrace",
                ],
                action: .actAllow,
                errnoRet: nil,
                args: []
            )
        )

        // include by arch
        if let archSyscalls = Self.defaultProfileArchSyscalls(arch) {
            syscalls.append(archSyscalls)
        }

        // Upstream walks the bounding set in order, so a repeated capability
        // produces a repeated group. Harmless, and preserved here.
        var admin = false
        for capability in capabilities?.bounding ?? [] {
            switch capability {
            case "CAP_DAC_READ_SEARCH":
                syscalls.append(
                    LinuxSyscall(names: ["open_by_handle_at"], action: .actAllow, errnoRet: nil, args: [])
                )
            case "CAP_SYS_ADMIN":
                admin = true
                syscalls.append(
                    LinuxSyscall(
                        names: [
                            "bpf",
                            "clone",
                            "clone3",
                            "fanotify_init",
                            "fsconfig",
                            "fsmount",
                            "fsopen",
                            "fspick",
                            "lookup_dcookie",
                            "mount",
                            "mount_setattr",
                            "move_mount",
                            "open_tree",
                            "perf_event_open",
                            "quotactl",
                            "quotactl_fd",
                            "setdomainname",
                            "sethostname",
                            "setns",
                            "syslog",
                            "umount",
                            "umount2",
                            "unshare",
                        ],
                        action: .actAllow,
                        errnoRet: nil,
                        args: []
                    )
                )
            case "CAP_SYS_BOOT":
                syscalls.append(
                    LinuxSyscall(names: ["reboot"], action: .actAllow, errnoRet: nil, args: [])
                )
            case "CAP_SYS_CHROOT":
                syscalls.append(
                    LinuxSyscall(names: ["chroot"], action: .actAllow, errnoRet: nil, args: [])
                )
            case "CAP_SYS_MODULE":
                syscalls.append(
                    LinuxSyscall(
                        names: [
                            "delete_module",
                            "init_module",
                            "finit_module",
                        ],
                        action: .actAllow,
                        errnoRet: nil,
                        args: []
                    )
                )
            case "CAP_SYS_PACCT":
                syscalls.append(
                    LinuxSyscall(names: ["acct"], action: .actAllow, errnoRet: nil, args: [])
                )
            case "CAP_SYS_PTRACE":
                syscalls.append(
                    LinuxSyscall(
                        names: [
                            "kcmp",
                            "pidfd_getfd",
                            "process_madvise",
                            "process_vm_readv",
                            "process_vm_writev",
                            "ptrace",
                        ],
                        action: .actAllow,
                        errnoRet: nil,
                        args: []
                    )
                )
            case "CAP_SYS_RAWIO":
                syscalls.append(
                    LinuxSyscall(
                        names: [
                            "iopl",
                            "ioperm",
                        ],
                        action: .actAllow,
                        errnoRet: nil,
                        args: []
                    )
                )
            case "CAP_SYS_TIME":
                syscalls.append(
                    LinuxSyscall(
                        names: [
                            "settimeofday",
                            "stime",
                            "clock_settime",
                            "clock_settime64",
                        ],
                        action: .actAllow,
                        errnoRet: nil,
                        args: []
                    )
                )
            case "CAP_SYS_TTY_CONFIG":
                syscalls.append(
                    LinuxSyscall(names: ["vhangup"], action: .actAllow, errnoRet: nil, args: [])
                )
            case "CAP_SYS_NICE":
                syscalls.append(
                    LinuxSyscall(
                        names: [
                            "get_mempolicy",
                            "mbind",
                            "set_mempolicy",
                            "set_mempolicy_home_node",  // kernel v5.17, libseccomp v2.5.4
                        ],
                        action: .actAllow,
                        errnoRet: nil,
                        args: []
                    )
                )
            case "CAP_SYSLOG":
                syscalls.append(
                    LinuxSyscall(names: ["syslog"], action: .actAllow, errnoRet: nil, args: [])
                )
            case "CAP_BPF":
                syscalls.append(
                    LinuxSyscall(names: ["bpf"], action: .actAllow, errnoRet: nil, args: [])
                )
            case "CAP_PERFMON":
                syscalls.append(
                    LinuxSyscall(names: ["perf_event_open"], action: .actAllow, errnoRet: nil, args: [])
                )
            default:
                continue
            }
        }

        if !admin {
            // Without CAP_SYS_ADMIN, `clone` is allowed only when it creates no
            // new namespace. s390/s390x swap the first two arguments of clone(2),
            // so the flags live in arg1 rather than arg0.
            let flagsIndex: UInt
            switch arch {
            case .archS390, .archS390X:
                flagsIndex = 1
            default:
                flagsIndex = 0
            }
            syscalls.append(
                LinuxSyscall(
                    names: ["clone"],
                    action: .actAllow,
                    errnoRet: nil,
                    args: [
                        LinuxSeccompArg(
                            index: flagsIndex,
                            value: Self.cloneNewNamespaceFlags,
                            valueTwo: 0,
                            op: .opMaskedEqual
                        )
                    ]
                )
            )
            // clone3 is explicitly requested to give ENOSYS instead of the default EPERM, when CAP_SYS_ADMIN is unset
            // https://github.com/moby/moby/pull/42681
            syscalls.append(
                LinuxSyscall(
                    names: ["clone3"],
                    action: .actErrno,
                    errnoRet: Self.enosys(arch),
                    args: []
                )
            )
        }

        return LinuxSeccomp(
            defaultAction: .actErrno,
            defaultErrnoRet: nil,
            architectures: Self.defaultProfileArchitectures(arch),
            flags: [],
            listenerPath: "",
            listenerMetadata: "",
            syscalls: syscalls
        )
    }
}

extension LinuxSeccomp {
    // Linux ABI constants, hardcoded because this code is compiled for the host
    // but describes a filter installed inside a Linux guest.

    /// `AF_ALG`, from `linux/socket.h`.
    private static let afALG: UInt64 = 38
    /// `AF_VSOCK`, from `linux/socket.h`.
    private static let afVSOCK: UInt64 = 40
    /// `ENOSYS` on `arch`.
    ///
    /// errno values are not uniform across Linux architectures — MIPS and
    /// PA-RISC carry their own `errno.h` — and upstream can hardcode
    /// `asm-generic`'s 38 only because it builds one binary per GOARCH. New
    /// ``Arch`` cases get the generic value.
    private static func enosys(_ arch: Arch) -> UInt {
        switch arch {
        case .archMIPS, .archMIPS64, .archMIPS64N32,
            .archMIPSEL, .archMIPSEL64, .archMIPSEL64N32:
            return 89
        case .archPARISC, .archPARISC64:
            return 251
        default:
            return 38
        }
    }
    /// `CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWUSER | CLONE_NEWPID
    /// | CLONE_NEWNET | CLONE_NEWCGROUP`, from `linux/sched.h`: 0x00020000 |
    /// 0x04000000 | 0x08000000 | 0x10000000 | 0x20000000 | 0x40000000 |
    /// 0x02000000.
    private static let cloneNewNamespaceFlags: UInt64 = 0x7E02_0000

    /// The seccomp architecture set a profile for `arch` should declare.
    ///
    /// Port of containerd's `arches()`, keyed on `runtime.GOARCH` upstream (the
    /// mapping is noted per case). An architecture upstream has no case for
    /// gets an empty list, leaving libseccomp with only the filtered process's
    /// native architecture.
    private static func defaultProfileArchitectures(_ arch: Arch) -> [Arch] {
        switch arch {
        case .archX86_64:  // GOARCH amd64
            return [.archX86_64, .archX86, .archX32]
        case .archAARCH64:  // GOARCH arm64
            return [.archARM, .archAARCH64]
        case .archMIPS64, .archMIPS64N32:  // GOARCH mips64, mips64n32
            return [.archMIPS, .archMIPS64, .archMIPS64N32]
        case .archMIPSEL64, .archMIPSEL64N32:  // GOARCH mipsel64, mipsel64n32
            return [.archMIPSEL, .archMIPSEL64, .archMIPSEL64N32]
        case .archS390, .archS390X:  // GOARCH s390, s390x
            return [.archS390, .archS390X]
        case .archRISCV64:  // GOARCH riscv64
            // SCMP_ARCH_RISCV32 does not exist, so there is no 32-bit companion.
            return [.archRISCV64]
        // Upstream `arches()` has no case for these, and returns an empty slice.
        // GOARCH arm and 386 land here even though both do get an
        // architecture-specific syscall group below.
        case .archX86, .archX32, .archARM, .archMIPS, .archMIPSEL,
            .archPPC, .archPPC64, .archPPC64LE, .archPARISC, .archPARISC64:
            return []
        }
    }

    /// The architecture-specific syscall group for `arch`, or `nil` when
    /// upstream adds none.
    ///
    /// Port of the "include by arch" switch in containerd's `DefaultProfile`,
    /// again keyed on `runtime.GOARCH` upstream.
    private static func defaultProfileArchSyscalls(_ arch: Arch) -> LinuxSyscall? {
        let names: [String]
        switch arch {
        case .archPPC64LE:  // GOARCH ppc64le
            names = [
                "sync_file_range2",
                "swapcontext",
            ]
        case .archARM, .archAARCH64:  // GOARCH arm, arm64
            names = [
                "arm_fadvise64_64",
                "arm_sync_file_range",
                "sync_file_range2",
                "breakpoint",
                "cacheflush",
                "set_tls",
            ]
        case .archX86_64:  // GOARCH amd64
            names = [
                "arch_prctl",
                "modify_ldt",
            ]
        case .archX86:  // GOARCH 386
            names = [
                "modify_ldt"
            ]
        case .archS390, .archS390X:  // GOARCH s390, s390x
            names = [
                "s390_pci_mmio_read",
                "s390_pci_mmio_write",
                "s390_runtime_instr",
            ]
        case .archRISCV64:  // GOARCH riscv64
            names = [
                "riscv_flush_icache",
                "riscv_hwprobe",  // kernel v6.12, libseccomp v2.6.0
            ]
        case .archX32, .archMIPS, .archMIPS64, .archMIPS64N32, .archMIPSEL,
            .archMIPSEL64, .archMIPSEL64N32, .archPPC, .archPPC64,
            .archPARISC, .archPARISC64:
            return nil
        }
        return LinuxSyscall(names: names, action: .actAllow, errnoRet: nil, args: [])
    }

    /// The unconditional allowlist every default profile starts from.
    ///
    /// Transcribed verbatim, in order, from the first `specs.LinuxSyscall` entry
    /// of containerd's `DefaultProfile`. The trailing comments are upstream's
    /// and record the kernel / libseccomp release that introduced a name.
    private static let defaultProfileBaseSyscalls: [String] = [
        "accept",
        "accept4",
        "access",
        "adjtimex",
        "alarm",
        "bind",
        "brk",
        "cachestat",  // kernel v6.5, libseccomp v2.5.5
        "capget",
        "capset",
        "chdir",
        "chmod",
        "chown",
        "chown32",
        "clock_adjtime",
        "clock_adjtime64",
        "clock_getres",
        "clock_getres_time64",
        "clock_gettime",
        "clock_gettime64",
        "clock_nanosleep",
        "clock_nanosleep_time64",
        "close",
        "close_range",
        "connect",
        "copy_file_range",
        "creat",
        "dup",
        "dup2",
        "dup3",
        "epoll_create",
        "epoll_create1",
        "epoll_ctl",
        "epoll_ctl_old",
        "epoll_pwait",
        "epoll_pwait2",
        "epoll_wait",
        "epoll_wait_old",
        "eventfd",
        "eventfd2",
        "execve",
        "execveat",
        "exit",
        "exit_group",
        "faccessat",
        "faccessat2",
        "fadvise64",
        "fadvise64_64",
        "fallocate",
        "fanotify_mark",
        "fchdir",
        "fchmod",
        "fchmodat",
        "fchmodat2",  // kernel v6.6, libseccomp v2.5.5
        "fchown",
        "fchown32",
        "fchownat",
        "fcntl",
        "fcntl64",
        "fdatasync",
        "fgetxattr",
        "flistxattr",
        "flock",
        "fork",
        "fremovexattr",
        "fsetxattr",
        "fstat",
        "fstat64",
        "fstatat64",
        "fstatfs",
        "fstatfs64",
        "fsync",
        "ftruncate",
        "ftruncate64",
        "futex",
        "futex_requeue",  // kernel v6.7, libseccomp v2.5.5
        "futex_time64",
        "futex_wait",  // kernel v6.7, libseccomp v2.5.5
        "futex_waitv",
        "futex_wake",  // kernel v6.7, libseccomp v2.5.5
        "futimesat",
        "getcpu",
        "getcwd",
        "getdents",
        "getdents64",
        "getegid",
        "getegid32",
        "geteuid",
        "geteuid32",
        "getgid",
        "getgid32",
        "getgroups",
        "getgroups32",
        "getitimer",
        "getpeername",
        "getpgid",
        "getpgrp",
        "getpid",
        "getppid",
        "getpriority",
        "getrandom",
        "getresgid",
        "getresgid32",
        "getresuid",
        "getresuid32",
        "getrlimit",
        "get_robust_list",
        "getrusage",
        "getsid",
        "getsockname",
        "getsockopt",
        "get_thread_area",
        "gettid",
        "gettimeofday",
        "getuid",
        "getuid32",
        "getxattr",
        "getxattrat",  // kernel v6.13, libseccomp v2.6.0
        "inotify_add_watch",
        "inotify_init",
        "inotify_init1",
        "inotify_rm_watch",
        "io_cancel",
        "ioctl",
        "io_destroy",
        "io_getevents",
        "io_pgetevents",
        "io_pgetevents_time64",
        "ioprio_get",
        "ioprio_set",
        "io_setup",
        "io_submit",
        "ipc",
        "kill",
        "landlock_add_rule",
        "landlock_create_ruleset",
        "landlock_restrict_self",
        "lchown",
        "lchown32",
        "lgetxattr",
        "link",
        "linkat",
        "listen",
        "listmount",  // kernel v6.8, libseccomp v2.6.0
        "listxattr",
        "listxattrat",  // kernel v6.13, libseccomp v2.6.0
        "llistxattr",
        "_llseek",
        "lremovexattr",
        "lseek",
        "lsetxattr",
        "lsm_get_self_attr",  // kernel v6.8, libseccomp v2.6.0
        "lsm_list_modules",  // kernel v6.8, libseccomp v2.6.0
        "lsm_set_self_attr",  // kernel v6.8, libseccomp v2.6.0
        "lstat",
        "lstat64",
        "madvise",
        "membarrier",
        "memfd_create",
        "memfd_secret",
        "mincore",
        "mkdir",
        "mkdirat",
        "mknod",
        "mknodat",
        "mlock",
        "mlock2",
        "mlockall",
        "map_shadow_stack",  // kernel v6.6, libseccomp v2.5.5
        "mmap",
        "mmap2",
        "mprotect",
        "mq_getsetattr",
        "mq_notify",
        "mq_open",
        "mq_timedreceive",
        "mq_timedreceive_time64",
        "mq_timedsend",
        "mq_timedsend_time64",
        "mq_unlink",
        "mremap",
        "mseal",  // kernel v6.10, libseccomp v2.6.0
        "msgctl",
        "msgget",
        "msgrcv",
        "msgsnd",
        "msync",
        "munlock",
        "munlockall",
        "munmap",
        "name_to_handle_at",
        "nanosleep",
        "newfstatat",
        "_newselect",
        "open",
        "openat",
        "openat2",
        "pause",
        "pidfd_open",
        "pidfd_send_signal",
        "pipe",
        "pipe2",
        "pkey_alloc",
        "pkey_free",
        "pkey_mprotect",
        "poll",
        "ppoll",
        "ppoll_time64",
        "prctl",
        "pread64",
        "preadv",
        "preadv2",
        "prlimit64",
        "process_mrelease",
        "pselect6",
        "pselect6_time64",
        "pwrite64",
        "pwritev",
        "pwritev2",
        "read",
        "readahead",
        "readlink",
        "readlinkat",
        "readv",
        "recv",
        "recvfrom",
        "recvmmsg",
        "recvmmsg_time64",
        "recvmsg",
        "remap_file_pages",
        "removexattr",
        "removexattrat",  // kernel v6.13, libseccomp v2.6.0
        "rename",
        "renameat",
        "renameat2",
        "restart_syscall",
        "rmdir",
        "rseq",
        "rt_sigaction",
        "rt_sigpending",
        "rt_sigprocmask",
        "rt_sigqueueinfo",
        "rt_sigreturn",
        "rt_sigsuspend",
        "rt_sigtimedwait",
        "rt_sigtimedwait_time64",
        "rt_tgsigqueueinfo",
        "sched_getaffinity",
        "sched_getattr",
        "sched_getparam",
        "sched_get_priority_max",
        "sched_get_priority_min",
        "sched_getscheduler",
        "sched_rr_get_interval",
        "sched_rr_get_interval_time64",
        "sched_setaffinity",
        "sched_setattr",
        "sched_setparam",
        "sched_setscheduler",
        "sched_yield",
        "seccomp",
        "select",
        "semctl",
        "semget",
        "semop",
        "semtimedop",
        "semtimedop_time64",
        "send",
        "sendfile",
        "sendfile64",
        "sendmmsg",
        "sendmsg",
        "sendto",
        "setfsgid",
        "setfsgid32",
        "setfsuid",
        "setfsuid32",
        "setgid",
        "setgid32",
        "setgroups",
        "setgroups32",
        "setitimer",
        "setpgid",
        "setpriority",
        "setregid",
        "setregid32",
        "setresgid",
        "setresgid32",
        "setresuid",
        "setresuid32",
        "setreuid",
        "setreuid32",
        "setrlimit",
        "set_robust_list",
        "setsid",
        "setsockopt",
        "set_thread_area",
        "set_tid_address",
        "setuid",
        "setuid32",
        "setxattr",
        "setxattrat",  // kernel v6.13, libseccomp v2.6.0
        "shmat",
        "shmctl",
        "shmdt",
        "shmget",
        "shutdown",
        "sigaltstack",
        "signalfd",
        "signalfd4",
        "sigprocmask",
        "sigreturn",
        "socketcall",
        "socketpair",
        "splice",
        "stat",
        "stat64",
        "statfs",
        "statfs64",
        "statmount",  // kernel v6.8, libseccomp v2.6.0
        "statx",
        "symlink",
        "symlinkat",
        "sync",
        "sync_file_range",
        "syncfs",
        "sysinfo",
        "tee",
        "tgkill",
        "time",
        "timer_create",
        "timer_delete",
        "timer_getoverrun",
        "timer_gettime",
        "timer_gettime64",
        "timer_settime",
        "timer_settime64",
        "timerfd_create",
        "timerfd_gettime",
        "timerfd_gettime64",
        "timerfd_settime",
        "timerfd_settime64",
        "times",
        "tkill",
        "truncate",
        "truncate64",
        "ugetrlimit",
        "umask",
        "uname",
        "unlink",
        "unlinkat",
        "uretprobe",  // kernel v6.11, libseccomp v2.6.0
        "utime",
        "utimensat",
        "utimensat_time64",
        "utimes",
        "vfork",
        "vmsplice",
        "wait4",
        "waitid",
        "waitpid",
        "write",
        "writev",
    ]
}

extension Arch {
    /// The seccomp architecture token for the architecture this code was
    /// *compiled* for, or `nil` when ``Arch`` cannot name it.
    ///
    /// This is a build-time constant, not a property of the machine. Prefer
    /// ``currentVerified()`` when what you actually want is the architecture a
    /// profile will be installed on.
    public static var current: Arch? {
        #if arch(arm64)
        return .archAARCH64
        #elseif arch(x86_64)
        return .archX86_64
        #elseif arch(arm)
        return .archARM
        #elseif arch(i386)
        return .archX86
        #elseif arch(s390x)
        return .archS390X
        #elseif arch(powerpc64)
        return .archPPC64
        #elseif arch(powerpc64le)
        return .archPPC64LE
        #elseif arch(riscv64)
        return .archRISCV64
        #else
        return nil
        #endif
    }

    /// The seccomp architecture to build a guest profile for, checked against
    /// the architecture actually running.
    ///
    /// ``current`` is a build-time constant while the guest's architecture is
    /// the host's, and nothing makes the two agree. A mismatch produces a
    /// silently wrong profile, so this compares against ``Platform/current``
    /// (which reads `uname`) and refuses instead.
    ///
    /// - Throws: `ContainerizationError(.unsupported)` when ``Arch`` cannot
    ///   name the architecture, or when the running architecture is not the one
    ///   this binary was built for.
    public static func currentVerified() throws -> Arch {
        guard let arch = Self.current else {
            throw ContainerizationError(
                .unsupported,
                message: "no default seccomp profile is available for this architecture"
            )
        }
        let running = Platform.current.architecture
        guard arch.hostArchitectureNames.contains(running) else {
            throw ContainerizationError(
                .unsupported,
                message: "seccomp architecture mismatch: built for \(arch.rawValue) but running on \(running); the profile would describe the wrong machine"
            )
        }
        return arch
    }

    /// The ``Platform/architecture`` spellings that correspond to this seccomp
    /// architecture.
    ///
    /// Only the cases ``current`` can return need an entry; the rest are
    /// unreachable from ``currentVerified()`` and read as a mismatch.
    /// ``Platform`` passes architectures it doesn't know through verbatim,
    /// hence the raw `i?86` spellings.
    private var hostArchitectureNames: Set<String> {
        switch self {
        case .archAARCH64:
            return ["arm64"]
        case .archX86_64:
            return ["amd64"]
        case .archARM:
            return ["arm"]
        case .archX86:
            return ["386", "i386", "i486", "i586", "i686"]
        case .archS390X:
            return ["s390x"]
        case .archPPC64:
            return ["ppc64"]
        case .archPPC64LE:
            return ["ppc64le"]
        case .archRISCV64:
            return ["riscv64"]
        case .archX32, .archMIPS, .archMIPS64, .archMIPS64N32, .archMIPSEL,
            .archMIPSEL64, .archMIPSEL64N32, .archPPC, .archS390,
            .archPARISC, .archPARISC64:
            return []
        }
    }
}
