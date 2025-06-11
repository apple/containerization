//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

/// NOTE: This is not a complete recreation of the runtime spec. Other platforms outside of Linux
/// have been left off, and some APIs for Linux aren't present. This was manually ported starting
/// at the v1.2.0 release.

public struct Spec: Codable, Sendable {
    public var version: String
    public var hooks: Hook?
    public var process: Process?
    public var hostname, domainname: String
    public var mounts: [Mount]
    public var annotations: [String: String]?
    public var root: Root?
    public var linux: Linux?

    public init(
        version: String = "",
        hooks: Hook? = nil,
        process: Process? = nil,
        hostname: String = "",
        domainname: String = "",
        mounts: [Mount] = [],
        annotations: [String: String]? = nil,
        root: Root? = nil,
        linux: Linux? = nil
    ) {
        self.version = version
        self.hooks = hooks
        self.process = process
        self.hostname = hostname
        self.domainname = domainname
        self.mounts = mounts
        self.annotations = annotations
        self.root = root
        self.linux = linux
    }

    public enum CodingKeys: String, CodingKey {
        case version = "ociVersion"
        case hooks
        case process
        case hostname
        case domainname
        case mounts
        case annotations
        case root
        case linux
    }
}

public struct Process: Codable, Sendable {
    public var cwd: String
    public var env: [String]
    public var consoleSize: Box?
    public var selinuxLabel: String
    public var noNewPrivileges: Bool
    public var commandLine: String
    public var oomScoreAdj: Int?
    public var capabilities: LinuxCapabilities?
    public var apparmorProfile: String
    public var user: User
    public var rlimits: [POSIXRlimit]
    public var args: [String]
    public var terminal: Bool

    public init(
        args: [String] = [],
        cwd: String = "/",
        env: [String] = [],
        consoleSize: Box? = nil,
        selinuxLabel: String = "",
        noNewPrivileges: Bool = false,
        commandLine: String = "",
        oomScoreAdj: Int? = nil,
        capabilities: LinuxCapabilities? = nil,
        apparmorProfile: String = "",
        user: User = .init(),
        rlimits: [POSIXRlimit] = [],
        terminal: Bool = false
    ) {
        self.cwd = cwd
        self.env = env
        self.consoleSize = consoleSize
        self.selinuxLabel = selinuxLabel
        self.noNewPrivileges = noNewPrivileges
        self.commandLine = commandLine
        self.oomScoreAdj = oomScoreAdj
        self.capabilities = capabilities
        self.apparmorProfile = apparmorProfile
        self.user = user
        self.rlimits = rlimits
        self.args = args
        self.terminal = terminal
    }

    public init(from config: ImageConfig) {
        let cwd = config.workingDir ?? "/"
        let env = config.env ?? []
        let args = (config.entrypoint ?? []) + (config.cmd ?? [])
        let user: User = {
            if let rawString = config.user {
                return User(username: rawString)
            }
            return User()
        }()
        self.init(args: args, cwd: cwd, env: env, user: user)
    }
}

public struct LinuxCapabilities: Codable, Sendable {
    public var bounding: [String]
    public var effective: [String]
    public var inheritable: [String]
    public var permitted: [String]
    public var ambient: [String]

    public init(
        bounding: [String],
        effective: [String],
        inheritable: [String],
        permitted: [String],
        ambient: [String]
    ) {
        self.bounding = bounding
        self.effective = effective
        self.inheritable = inheritable
        self.permitted = permitted
        self.ambient = ambient
    }
}

public struct Box: Codable, Sendable {
    var height, width: UInt

    public init(height: UInt, width: UInt) {
        self.height = height
        self.width = width
    }
}

public struct User: Codable, Sendable {
    public var uid: UInt32
    public var gid: UInt32
    public var umask: UInt32?
    public var additionalGids: [UInt32]
    public var username: String

    public init(
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        umask: UInt32? = nil,
        additionalGids: [UInt32] = [],
        username: String = ""
    ) {
        self.uid = uid
        self.gid = gid
        self.umask = umask
        self.additionalGids = additionalGids
        self.username = username
    }
}

public struct Root: Codable, Sendable {
    public var path: String
    public var readonly: Bool

    public init(path: String, readonly: Bool) {
        self.path = path
        self.readonly = readonly
    }
}

public struct Mount: Codable, Sendable {
    public var type: String
    public var source: String
    public var destination: String
    public var options: [String]

    public var uidMappings: [LinuxIDMapping]
    public var gidMappings: [LinuxIDMapping]

    public init(
        type: String,
        source: String,
        destination: String,
        options: [String] = [],
        uidMappings: [LinuxIDMapping] = [],
        gidMappings: [LinuxIDMapping] = []
    ) {
        self.destination = destination
        self.type = type
        self.source = source
        self.options = options
        self.uidMappings = uidMappings
        self.gidMappings = gidMappings
    }
}

public struct Hook: Codable, Sendable {
    public var path: String
    public var args: [String]
    public var env: [String]
    public var timeout: Int?

    public init(path: String, args: [String], env: [String], timeout: Int?) {
        self.path = path
        self.args = args
        self.env = env
        self.timeout = timeout
    }
}

public struct Hooks: Codable, Sendable {
    public var prestart: [Hook]
    public var createRuntime: [Hook]
    public var createContainer: [Hook]
    public var startContainer: [Hook]
    public var poststart: [Hook]
    public var poststop: [Hook]

    public init(
        prestart: [Hook],
        createRuntime: [Hook],
        createContainer: [Hook],
        startContainer: [Hook],
        poststart: [Hook],
        poststop: [Hook]
    ) {
        self.prestart = prestart
        self.createRuntime = createRuntime
        self.createContainer = createContainer
        self.startContainer = startContainer
        self.poststart = poststart
        self.poststop = poststop
    }
}

public struct Linux: Codable, Sendable {
    public var uidMappings: [LinuxIDMapping]
    public var gidMappings: [LinuxIDMapping]
    public var sysctl: [String: String]?
    public var resources: LinuxResources?
    public var cgroupsPath: String
    public var namespaces: [LinuxNamespace]
    public var devices: [LinuxDevice]
    public var seccomp: LinuxSeccomp?
    public var rootfsPropagation: String
    public var maskedPaths: [String]
    public var readonlyPaths: [String]
    public var mountLabel: String
    public var personality: LinuxPersonality?

    public init(
        uidMappings: [LinuxIDMapping] = [],
        gidMappings: [LinuxIDMapping] = [],
        sysctl: [String: String]? = nil,
        resources: LinuxResources? = nil,
        cgroupsPath: String = "",
        namespaces: [LinuxNamespace] = [],
        devices: [LinuxDevice] = [],
        seccomp: LinuxSeccomp? = nil,
        rootfsPropagation: String = "",
        maskedPaths: [String] = [],
        readonlyPaths: [String] = [],
        mountLabel: String = "",
        personality: LinuxPersonality? = nil
    ) {
        self.uidMappings = uidMappings
        self.gidMappings = gidMappings
        self.sysctl = sysctl
        self.resources = resources
        self.cgroupsPath = cgroupsPath
        self.namespaces = namespaces
        self.devices = devices
        self.seccomp = seccomp
        self.rootfsPropagation = rootfsPropagation
        self.maskedPaths = maskedPaths
        self.readonlyPaths = readonlyPaths
        self.mountLabel = mountLabel
        self.personality = personality
    }
}

public struct LinuxNamespace: Codable, Sendable {
    public var type: LinuxNamespaceType
    public var path: String

    public init(type: LinuxNamespaceType, path: String = "") {
        self.type = type
        self.path = path
    }
}

public enum LinuxNamespaceType: String, Codable, Sendable {
    case pid
    case network
    case uts
    case mount
    case ipc
    case user
    case cgroup
}

public struct LinuxIDMapping: Codable, Sendable {
    public var containerID: UInt32
    public var hostID: UInt32
    public var size: UInt32

    public init(containerID: UInt32, hostID: UInt32, size: UInt32) {
        self.containerID = containerID
        self.hostID = hostID
        self.size = size
    }
}

public struct POSIXRlimit: Codable, Sendable {
    public var type: String
    public var hard: UInt64
    public var soft: UInt64

    public init(type: String, hard: UInt64, soft: UInt64) {
        self.type = type
        self.hard = hard
        self.soft = soft
    }
}

public struct LinuxHugepageLimit: Codable, Sendable {
    public var pagesize: String
    public var limit: UInt64

    public init(pagesize: String, limit: UInt64) {
        self.pagesize = pagesize
        self.limit = limit
    }
}

public struct LinuxInterfacePriority: Codable, Sendable {
    public var name: String
    public var priority: UInt32

    public init(name: String, priority: UInt32) {
        self.name = name
        self.priority = priority
    }
}

public struct LinuxBlockIODevice: Codable, Sendable {
    public var major: Int64
    public var minor: Int64

    public init(major: Int64, minor: Int64) {
        self.major = major
        self.minor = minor
    }
}

public struct LinuxWeightDevice: Codable, Sendable {
    public var major: Int64
    public var minor: Int64
    public var weight: UInt16?
    public var leafWeight: UInt16?

    public init(major: Int64, minor: Int64, weight: UInt16?, leafWeight: UInt16?) {
        self.major = major
        self.minor = minor
        self.weight = weight
        self.leafWeight = leafWeight
    }
}

public struct LinuxThrottleDevice: Codable, Sendable {
    public var major: Int64
    public var minor: Int64
    public var rate: UInt64

    public init(major: Int64, minor: Int64, rate: UInt64) {
        self.major = major
        self.minor = minor
        self.rate = rate
    }
}

public struct LinuxBlockIO: Codable, Sendable {
    public var weight: UInt16?
    public var leafWeight: UInt16?
    public var weightDevice: [LinuxWeightDevice]
    public var throttleReadBpsDevice: [LinuxThrottleDevice]
    public var throttleWriteBpsDevice: [LinuxThrottleDevice]
    public var throttleReadIOPSDevice: [LinuxThrottleDevice]
    public var throttleWriteIOPSDevice: [LinuxThrottleDevice]

    public init(
        weight: UInt16?,
        leafWeight: UInt16?,
        weightDevice: [LinuxWeightDevice],
        throttleReadBpsDevice: [LinuxThrottleDevice],
        throttleWriteBpsDevice: [LinuxThrottleDevice],
        throttleReadIOPSDevice: [LinuxThrottleDevice],
        throttleWriteIOPSDevice: [LinuxThrottleDevice]
    ) {
        self.weight = weight
        self.leafWeight = leafWeight
        self.weightDevice = weightDevice
        self.throttleReadBpsDevice = throttleReadBpsDevice
        self.throttleWriteBpsDevice = throttleWriteBpsDevice
        self.throttleReadIOPSDevice = throttleReadIOPSDevice
        self.throttleWriteIOPSDevice = throttleWriteIOPSDevice
    }
}

public struct LinuxMemory: Codable, Sendable {
    public var limit: Int64?
    public var reservation: Int64?
    public var swap: Int64?
    public var kernel: Int64?
    public var kernelTCP: Int64?
    public var swappiness: UInt64?
    public var disableOOMKiller: Bool?
    public var useHierarchy: Bool?
    public var checkBeforeUpdate: Bool?

    public init(
        limit: Int64? = nil,
        reservation: Int64? = nil,
        swap: Int64? = nil,
        kernel: Int64? = nil,
        kernelTCP: Int64? = nil,
        swappiness: UInt64? = nil,
        disableOOMKiller: Bool? = nil,
        useHierarchy: Bool? = nil,
        checkBeforeUpdate: Bool? = nil
    ) {
        self.limit = limit
        self.reservation = reservation
        self.swap = swap
        self.kernel = kernel
        self.kernelTCP = kernelTCP
        self.swappiness = swappiness
        self.disableOOMKiller = disableOOMKiller
        self.useHierarchy = useHierarchy
        self.checkBeforeUpdate = checkBeforeUpdate
    }
}

public struct LinuxCPU: Codable, Sendable {
    public var shares: UInt64?
    public var quota: Int64?
    public var burst: UInt64?
    public var period: UInt64?
    public var realtimeRuntime: Int64?
    public var realtimePeriod: Int64?
    public var cpus: String
    public var mems: String
    public var idle: Int64?

    public init(
        shares: UInt64?,
        quota: Int64?,
        burst: UInt64?,
        period: UInt64?,
        realtimeRuntime: Int64?,
        realtimePeriod: Int64?,
        cpus: String,
        mems: String,
        idle: Int64?
    ) {
        self.shares = shares
        self.quota = quota
        self.burst = burst
        self.period = period
        self.realtimeRuntime = realtimeRuntime
        self.realtimePeriod = realtimePeriod
        self.cpus = cpus
        self.mems = mems
        self.idle = idle
    }
}

public struct LinuxPids: Codable, Sendable {
    public var limit: Int64

    public init(limit: Int64) {
        self.limit = limit
    }
}

public struct LinuxNetwork: Codable, Sendable {
    public var classID: UInt32?
    public var priorities: [LinuxInterfacePriority]

    public init(classID: UInt32?, priorities: [LinuxInterfacePriority]) {
        self.classID = classID
        self.priorities = priorities
    }
}

public struct LinuxRdma: Codable, Sendable {
    public var hcsHandles: UInt32?
    public var hcaObjects: UInt32?

    public init(hcsHandles: UInt32?, hcaObjects: UInt32?) {
        self.hcsHandles = hcsHandles
        self.hcaObjects = hcaObjects
    }
}

public struct LinuxResources: Codable, Sendable {
    public var devices: [LinuxDeviceCgroup]
    public var memory: LinuxMemory?
    public var cpu: LinuxCPU?
    public var pids: LinuxPids?
    public var blockIO: LinuxBlockIO?
    public var hugepageLimits: [LinuxHugepageLimit]
    public var network: LinuxNetwork?
    public var rdma: [String: LinuxRdma]?
    public var unified: [String: String]?

    public init(
        devices: [LinuxDeviceCgroup] = [],
        memory: LinuxMemory? = nil,
        cpu: LinuxCPU? = nil,
        pids: LinuxPids? = nil,
        blockIO: LinuxBlockIO? = nil,
        hugepageLimits: [LinuxHugepageLimit] = [],
        network: LinuxNetwork? = nil,
        rdma: [String: LinuxRdma]? = nil,
        unified: [String: String] = [:]
    ) {
        self.devices = devices
        self.memory = memory
        self.cpu = cpu
        self.pids = pids
        self.blockIO = blockIO
        self.hugepageLimits = hugepageLimits
        self.network = network
        self.rdma = rdma
        self.unified = unified
    }
}

public struct LinuxDevice: Codable, Sendable {
    public var path: String
    public var type: String
    public var major: Int64
    public var minor: Int64
    public var fileMode: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?

    public init(
        path: String,
        type: String,
        major: Int64,
        minor: Int64,
        fileMode: UInt32?,
        uid: UInt32?,
        gid: UInt32?
    ) {
        self.path = path
        self.type = type
        self.major = major
        self.minor = minor
        self.fileMode = fileMode
        self.uid = uid
        self.gid = gid
    }
}

public struct LinuxDeviceCgroup: Codable, Sendable {
    public var allow: Bool
    public var type: String
    public var major: Int64?
    public var minor: Int64?
    public var access: String?

    public init(allow: Bool, type: String, major: Int64?, minor: Int64?, access: String?) {
        self.allow = allow
        self.type = type
        self.major = major
        self.minor = minor
        self.access = access
    }
}

public enum LinuxPersonalityDomain: String, Codable, Sendable {
    case perLinux = "LINUX"
    case perLinux32 = "LINUX32"
}

public struct LinuxPersonality: Codable, Sendable {
    public var domain: LinuxPersonalityDomain
    public var flags: [String]

    public init(domain: LinuxPersonalityDomain, flags: [String]) {
        self.domain = domain
        self.flags = flags
    }
}

public struct LinuxSeccomp: Codable, Sendable {
    public var defaultAction: LinuxSeccompAction
    public var defaultErrnoRet: UInt?
    public var architectures: [Arch]
    public var flags: [LinuxSeccompFlag]
    public var listenerPath: String
    public var listenerMetadata: String
    public var syscalls: [LinuxSyscall]

    public init(
        defaultAction: LinuxSeccompAction,
        defaultErrnoRet: UInt?,
        architectures: [Arch],
        flags: [LinuxSeccompFlag],
        listenerPath: String,
        listenerMetadata: String,
        syscalls: [LinuxSyscall]
    ) {
        self.defaultAction = defaultAction
        self.defaultErrnoRet = defaultErrnoRet
        self.architectures = architectures
        self.flags = flags
        self.listenerPath = listenerPath
        self.listenerMetadata = listenerMetadata
        self.syscalls = syscalls
    }
}

public enum LinuxSeccompFlag: String, Codable, Sendable {
    case flagLog = "SECCOMP_FILTER_FLAG_LOG"
    case flagSpecAllow = "SECCOMP_FILTER_FLAG_SPEC_ALLOW"
    case flagWaitKillableRecv = "SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV"
}

public enum Arch: String, Codable, Sendable {
    case archX86 = "SCMP_ARCH_X86"
    case archX86_64 = "SCMP_ARCH_X86_64"
    case archX32 = "SCMP_ARCH_X32"
    case archARM = "SCMP_ARCH_ARM"
    case archAARCH64 = "SCMP_ARCH_AARCH64"
    case archMIPS = "SCMP_ARCH_MIPS"
    case archMIPS64 = "SCMP_ARCH_MIPS64"
    case archMIPS64N32 = "SCMP_ARCH_MIPS64N32"
    case archMIPSEL = "SCMP_ARCH_MIPSEL"
    case archMIPSEL64 = "SCMP_ARCH_MIPSEL64"
    case archMIPSEL64N32 = "SCMP_ARCH_MIPSEL64N32"
    case archPPC = "SCMP_ARCH_PPC"
    case archPPC64 = "SCMP_ARCH_PPC64"
    case archPPC64LE = "SCMP_ARCH_PPC64LE"
    case archS390 = "SCMP_ARCH_S390"
    case archS390X = "SCMP_ARCH_S390X"
    case archPARISC = "SCMP_ARCH_PARISC"
    case archPARISC64 = "SCMP_ARCH_PARISC64"
    case archRISCV64 = "SCMP_ARCH_RISCV64"
}

public enum LinuxSeccompAction: String, Codable, Sendable {
    case actKill = "SCMP_ACT_KILL"
    case actKillProcess = "SCMP_ACT_KILL_PROCESS"
    case actKillThread = "SCMP_ACT_KILL_THREAD"
    case actTrap = "SCMP_ACT_TRAP"
    case actErrno = "SCMP_ACT_ERRNO"
    case actTrace = "SCMP_ACT_TRACE"
    case actAllow = "SCMP_ACT_ALLOW"
    case actLog = "SCMP_ACT_LOG"
    case actNotify = "SCMP_ACT_NOTIFY"
}

public enum LinuxSeccompOperator: String, Codable, Sendable {
    case opNotEqual = "SCMP_CMP_NE"
    case opLessThan = "SCMP_CMP_LT"
    case opLessEqual = "SCMP_CMP_LE"
    case opEqualTo = "SCMP_CMP_EQ"
    case opGreaterEqual = "SCMP_CMP_GE"
    case opGreaterThan = "SCMP_CMP_GT"
    case opMaskedEqual = "SCMP_CMP_MASKED_EQ"
}

public struct LinuxSeccompArg: Codable, Sendable {
    public var index: UInt
    public var value: UInt64
    public var valueTwo: UInt64
    public var op: LinuxSeccompOperator

    public init(index: UInt, value: UInt64, valueTwo: UInt64, op: LinuxSeccompOperator) {
        self.index = index
        self.value = value
        self.valueTwo = valueTwo
        self.op = op
    }
}

public struct LinuxSyscall: Codable, Sendable {
    public var names: [String]
    public var action: LinuxSeccompAction
    public var errnoRet: UInt?
    public var args: [LinuxSeccompArg]

    public init(
        names: [String],
        action: LinuxSeccompAction,
        errnoRet: UInt?,
        args: [LinuxSeccompArg]
    ) {
        self.names = names
        self.action = action
        self.errnoRet = errnoRet
        self.args = args
    }
}
