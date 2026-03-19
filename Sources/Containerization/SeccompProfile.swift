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

import ContainerizationOCI
import ContainerizationOS

/// Seccomp configuration.
public struct SeccompProfile: Sendable {
    /// The action to take for syscalls not matched by any rule.
    public var defaultAction: Action
    /// Architecture constraints.
    public var architectures: [Architecture]
    /// Seccomp filter flags.
    public var flags: [Flag]
    /// Per-syscall rules.
    public var syscalls: [Rule]

    /// The action to take for a matching syscall.
    ///
    /// Note: `SECCOMP_RET_TRACE` and `SECCOMP_RET_USER_NOTIF` are not
    /// supported. Both require a host-side (in our case guest) process
    // (ptrace tracer or seccomp notify listener).
    public enum Action: Sendable {
        case allow
        case kill
        case killProcess
        case trap
        case errno(UInt)
        case log
    }

    /// Supported architectures.
    public enum Architecture: Sendable {
        case aarch64
    }

    /// Seccomp filter flags.
    public enum Flag: Sendable {
        case log
        case specAllow
        case waitKillableRecv
    }

    /// Identifies a syscall by name or raw number.
    public enum Syscall: Sendable, ExpressibleByStringLiteral {
        /// A syscall name (e.g. "mkdirat"). Must match an entry in the
        /// aarch64 syscall table; unknown names are silently skipped.
        case name(String)
        /// A raw syscall number. Useful for newly added syscalls.
        case number(UInt32)

        public init(stringLiteral value: String) {
            self = .name(value)
        }
    }

    /// A rule that matches one or more syscalls.
    public struct Rule: Sendable {
        /// The syscalls this rule matches.
        public var syscalls: [Syscall]
        /// The action to take when matched.
        public var action: Action
        /// Optional argument conditions (all must match).
        public var args: [ArgCondition]
        /// Capabilities required for this rule to be included in the filter.
        /// If non-empty, the rule is only emitted when the container has all
        /// of these capabilities in its effective set.
        public var requiredCapabilities: [CapabilityName]

        public init(
            syscalls: [Syscall],
            action: Action,
            args: [ArgCondition] = [],
            requiredCapabilities: [CapabilityName] = []
        ) {
            self.syscalls = syscalls
            self.action = action
            self.args = args
            self.requiredCapabilities = requiredCapabilities
        }
    }

    /// A condition on a syscall argument.
    public struct ArgCondition: Sendable {
        /// The argument index (0-5).
        public var index: UInt
        /// The comparison operator.
        public var op: Operator
        /// The value to compare against.
        public var value: UInt64
        /// Second value (used with maskedEqual).
        public var valueTwo: UInt64

        /// Comparison operators for argument conditions.
        public enum Operator: Sendable {
            case equalTo
            case notEqual
            case lessThan
            case lessEqual
            case greaterThan
            case greaterEqual
            case maskedEqual
        }

        public init(index: UInt, op: Operator, value: UInt64, valueTwo: UInt64 = 0) {
            self.index = index
            self.op = op
            self.value = value
            self.valueTwo = valueTwo
        }
    }

    /// A profile that allows all syscalls.
    public static let allowAll = SeccompProfile(defaultAction: .allow)

    /// Default seccomp profile for unprivileged containers.
    public static let defaultProfile: SeccompProfile = {
        var profile = SeccompProfile(defaultAction: .errno(1))
        profile.syscalls = [
            // Unconditional allowlist.
            Rule(
                syscalls: [
                    "accept",
                    "accept4",
                    "access",
                    "adjtimex",
                    "alarm",
                    "bind",
                    "brk",
                    "cachestat",
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
                    "fchmodat2",
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
                    "fstatat",
                    "fstatat64",
                    "fstatfs",
                    "fstatfs64",
                    "fsync",
                    "ftruncate",
                    "ftruncate64",
                    "futex",
                    "futex_requeue",
                    "futex_time64",
                    "futex_wait",
                    "futex_waitv",
                    "futex_wake",
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
                    "getxattrat",
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
                    "add_key",
                    "keyctl",
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
                    "listmount",
                    "listxattr",
                    "listxattrat",
                    "llistxattr",
                    "_llseek",
                    "lremovexattr",
                    "lseek",
                    "lsetxattr",
                    "lstat",
                    "lstat64",
                    "madvise",
                    "map_shadow_stack",
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
                    "mseal",
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
                    "removexattrat",
                    "rename",
                    "renameat",
                    "renameat2",
                    "request_key",
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
                    "setxattrat",
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
                    "statmount",
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
                    "uretprobe",
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

                    // arm/arm64 specific
                    "arm_fadvise64_64",
                    "arm_sync_file_range",
                    "sync_file_range2",
                    "breakpoint",
                    "cacheflush",
                    "set_tls",
                ], action: .allow),

            // socket: allow all address families except AF_VSOCK (40).
            Rule(
                syscalls: ["socket"],
                action: .allow,
                args: [ArgCondition(index: 0, op: .notEqual, value: 40)]
            ),

            // personality: only allow specific execution domains.
            //   0x0        = PER_LINUX (default)
            //   0x8        = ADDR_NO_RANDOMIZE
            //   0x20000    = UNAME26 (report kernel as 2.6.x)
            //   0x20008    = UNAME26 | ADDR_NO_RANDOMIZE
            //   0xFFFFFFFF = query current personality
            Rule(
                syscalls: ["personality"],
                action: .allow,
                args: [ArgCondition(index: 0, op: .equalTo, value: 0x0)]
            ),
            Rule(
                syscalls: ["personality"],
                action: .allow,
                args: [ArgCondition(index: 0, op: .equalTo, value: 0x8)]
            ),
            Rule(
                syscalls: ["personality"],
                action: .allow,
                args: [ArgCondition(index: 0, op: .equalTo, value: 0x20000)]
            ),
            Rule(
                syscalls: ["personality"],
                action: .allow,
                args: [ArgCondition(index: 0, op: .equalTo, value: 0x20008)]
            ),
            Rule(
                syscalls: ["personality"],
                action: .allow,
                args: [ArgCondition(index: 0, op: .equalTo, value: 0xFFFF_FFFF)]
            ),

            // clone: allow only if no namespace creation flags are set.
            // The mask 0x7E020000 covers CLONE_NEWNS | CLONE_NEWCGROUP |
            // CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWUSER | CLONE_NEWPID |
            // CLONE_NEWNET. If (flags & mask) == 0, no namespaces are being
            // created and the clone is safe.
            Rule(
                syscalls: ["clone"],
                action: .allow,
                args: [ArgCondition(index: 0, op: .maskedEqual, value: 2_114_060_288, valueTwo: 0)]
            ),

            // clone3: return ENOSYS (38) to force glibc/musl to fall back to
            // clone, where we can inspect the flags via the arg filter above.
            // clone3 passes flags in a struct rather than a register, so BPF
            // cannot inspect them directly.
            Rule(syscalls: ["clone3"], action: .errno(38)),

            // Capability-gated rules. These are only included when the
            // container has the required capability in its effective set.

            // CAP_DAC_READ_SEARCH
            Rule(
                syscalls: ["open_by_handle_at"],
                action: .allow,
                requiredCapabilities: [.dacReadSearch]
            ),

            // CAP_SYS_ADMIN: allow clone/clone3 without namespace flag
            // restrictions, plus mount/namespace/admin syscalls.
            Rule(
                syscalls: [
                    "bpf", "clone", "clone3", "fanotify_init",
                    "fsconfig", "fsmount", "fsopen", "fspick",
                    "lookup_dcookie",
                    "mount", "mount_setattr", "move_mount", "open_tree",
                    "perf_event_open",
                    "quotactl", "quotactl_fd",
                    "setdomainname", "sethostname", "setns",
                    "syslog",
                    "umount", "umount2", "unshare",
                ],
                action: .allow,
                requiredCapabilities: [.sysAdmin]
            ),

            // CAP_SYS_BOOT
            Rule(
                syscalls: ["reboot"],
                action: .allow,
                requiredCapabilities: [.sysBoot]
            ),

            // CAP_SYS_CHROOT
            Rule(
                syscalls: ["chroot"],
                action: .allow,
                requiredCapabilities: [.sysChroot]
            ),

            // CAP_SYS_MODULE
            Rule(
                syscalls: ["delete_module", "init_module", "finit_module"],
                action: .allow,
                requiredCapabilities: [.sysModule]
            ),

            // CAP_SYS_PACCT
            Rule(
                syscalls: ["acct"],
                action: .allow,
                requiredCapabilities: [.sysPacct]
            ),

            // CAP_SYS_PTRACE
            Rule(
                syscalls: [
                    "kcmp", "pidfd_getfd", "process_madvise",
                    "process_vm_readv", "process_vm_writev", "ptrace",
                ],
                action: .allow,
                requiredCapabilities: [.sysPtrace]
            ),

            // CAP_SYS_RAWIO
            Rule(
                syscalls: ["iopl", "ioperm"],
                action: .allow,
                requiredCapabilities: [.sysRawio]
            ),

            // CAP_SYS_TIME
            Rule(
                syscalls: ["settimeofday", "stime", "clock_settime", "clock_settime64"],
                action: .allow,
                requiredCapabilities: [.sysTime]
            ),

            // CAP_SYS_TTY_CONFIG
            Rule(
                syscalls: ["vhangup"],
                action: .allow,
                requiredCapabilities: [.sysTtyConfig]
            ),

            // CAP_SYS_NICE
            Rule(
                syscalls: ["get_mempolicy", "mbind", "set_mempolicy", "set_mempolicy_home_node"],
                action: .allow,
                requiredCapabilities: [.sysNice]
            ),

            // CAP_SYSLOG
            Rule(
                syscalls: ["syslog"],
                action: .allow,
                requiredCapabilities: [.syslog]
            ),

            // CAP_BPF
            Rule(
                syscalls: ["bpf"],
                action: .allow,
                requiredCapabilities: [.bpf]
            ),

            // CAP_PERFMON
            Rule(
                syscalls: ["perf_event_open"],
                action: .allow,
                requiredCapabilities: [.perfmon]
            ),
        ]
        return profile
    }()

    public init(defaultAction: Action) {
        self.defaultAction = defaultAction
        self.architectures = [.aarch64]
        self.flags = []
        self.syscalls = []
    }

    /// Add a rule that allows the specified syscalls.
    public mutating func allow(_ names: String...) {
        syscalls.append(Rule(syscalls: names.map { .name($0) }, action: .allow))
    }

    /// Add a rule that returns the specified errno for the given syscalls.
    public mutating func errno(_ errnoVal: UInt, _ names: String...) {
        syscalls.append(Rule(syscalls: names.map { .name($0) }, action: .errno(errnoVal)))
    }

    /// Convert to OCI type for transport.
    ///
    /// Rules with `requiredCapabilities` are only included when the provided
    /// effective capabilities contain all required capabilities for that rule.
    public func toOCI(effectiveCapabilities: [CapabilityName] = []) -> ContainerizationOCI.LinuxSeccomp {
        let capSet = Set(effectiveCapabilities)
        let filteredSyscalls = syscalls.filter { rule in
            rule.requiredCapabilities.isEmpty || rule.requiredCapabilities.allSatisfy { capSet.contains($0) }
        }

        return ContainerizationOCI.LinuxSeccomp(
            defaultAction: defaultAction.toOCI(),
            defaultErrnoRet: defaultAction.ociErrnoRet,
            architectures: architectures.map { $0.toOCI() },
            flags: flags.map { $0.toOCI() },
            listenerPath: "",
            listenerMetadata: "",
            syscalls: filteredSyscalls.map { $0.toOCI() }
        )
    }
}

extension SeccompProfile.Action {
    func toOCI() -> LinuxSeccompAction {
        switch self {
        case .allow: return .actAllow
        case .kill: return .actKill
        case .killProcess: return .actKillProcess
        case .trap: return .actTrap
        case .errno: return .actErrno
        case .log: return .actLog
        }
    }

    var ociErrnoRet: UInt? {
        switch self {
        case .errno(let val): return val
        default: return nil
        }
    }
}

extension SeccompProfile.Architecture {
    func toOCI() -> Arch {
        switch self {
        case .aarch64: return .archAARCH64
        }
    }
}

extension SeccompProfile.Flag {
    func toOCI() -> LinuxSeccompFlag {
        switch self {
        case .log: return .flagLog
        case .specAllow: return .flagSpecAllow
        case .waitKillableRecv: return .flagWaitKillableRecv
        }
    }
}

extension SeccompProfile.Rule {
    func toOCI() -> LinuxSyscall {
        let errnoRet: UInt?
        switch action {
        case .errno(let val): errnoRet = val
        default: errnoRet = nil
        }

        let names = syscalls.map { syscall -> String in
            switch syscall {
            case .name(let n): return n
            case .number(let nr): return String(nr)
            }
        }

        return LinuxSyscall(
            names: names,
            action: action.toOCI(),
            errnoRet: errnoRet,
            args: args.map { $0.toOCI() }
        )
    }
}

extension SeccompProfile.ArgCondition {
    func toOCI() -> LinuxSeccompArg {
        LinuxSeccompArg(
            index: index,
            value: value,
            valueTwo: valueTwo,
            op: op.toOCI()
        )
    }
}

extension SeccompProfile.ArgCondition.Operator {
    func toOCI() -> LinuxSeccompOperator {
        switch self {
        case .equalTo: return .opEqualTo
        case .notEqual: return .opNotEqual
        case .lessThan: return .opLessThan
        case .lessEqual: return .opLessEqual
        case .greaterThan: return .opGreaterThan
        case .greaterEqual: return .opGreaterEqual
        case .maskedEqual: return .opMaskedEqual
        }
    }
}
