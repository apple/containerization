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

public struct OCISpec: Codable, Sendable {
    public var version: String
    public var hooks: OCIHook?
    public var process: OCIProcess?
    public var hostname, domainname: String
    public var mounts: [OCIMount]
    public var annotations: [String: String]?
    public var root: OCIRoot?
    public var linux: OCILinux?

    public init(
        version: String = "",
        hooks: OCIHook? = nil,
        process: OCIProcess? = nil,
        hostname: String = "",
        domainname: String = "",
        mounts: [OCIMount] = [],
        annotations: [String: String]? = nil,
        root: OCIRoot? = nil,
        linux: OCILinux? = nil
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

public struct OCIProcess: Codable, Sendable {
    public var cwd: String
    public var env: [String]
    public var consoleSize: OCIBox?
    public var selinuxLabel: String
    public var noNewPrivileges: Bool
    public var commandLine: String
    public var oomScoreAdj: Int?
    public var capabilities: OCILinuxCapabilities?
    public var apparmorProfile: String
    public var user: OCIUser
    public var rlimits: [OCIRlimit]
    public var args: [String]
    public var terminal: Bool

    public init(
        args: [String] = [],
        cwd: String = "/",
        env: [String] = [],
        consoleSize: OCIBox? = nil,
        selinuxLabel: String = "",
        noNewPrivileges: Bool = false,
        commandLine: String = "",
        oomScoreAdj: Int? = nil,
        capabilities: OCILinuxCapabilities? = nil,
        apparmorProfile: String = "",
        user: OCIUser = .init(),
        rlimits: [OCIRlimit] = [],
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

    public init(from config: OCIImageConfig) {
        let cwd = config.workingDir ?? "/"
        let env = config.env ?? []
        let args = (config.entrypoint ?? []) + (config.cmd ?? [])
        let user: OCIUser = {
            if let rawString = config.user {
                return OCIUser(username: rawString)
            }
            return OCIUser()
        }()
        self.init(args: args, cwd: cwd, env: env, user: user)
    }
}

public struct OCILinuxCapabilities: Codable, Sendable {
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

public struct OCIBox: Codable, Sendable {
    var height, width: UInt

    public init(height: UInt, width: UInt) {
        self.height = height
        self.width = width
    }
}

public struct OCIUser: Codable, Sendable {
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

public struct OCIRoot: Codable, Sendable {
    public var path: String
    public var readonly: Bool

    public init(path: String, readonly: Bool) {
        self.path = path
        self.readonly = readonly
    }
}

public struct OCIMount: Codable, Sendable {
    public var type: String
    public var source: String
    public var destination: String
    public var options: [String]

    public var uidMappings: [OCILinuxIDMapping]
    public var gidMappings: [OCILinuxIDMapping]

    public init(
        type: String,
        source: String,
        destination: String,
        options: [String] = [],
        uidMappings: [OCILinuxIDMapping] = [],
        gidMappings: [OCILinuxIDMapping] = []
    ) {
        self.destination = destination
        self.type = type
        self.source = source
        self.options = options
        self.uidMappings = uidMappings
        self.gidMappings = gidMappings
    }
}

public struct OCIHook: Codable, Sendable {
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

public struct OCIHooks: Codable, Sendable {
    public var prestart: [OCIHook]
    public var createRuntime: [OCIHook]
    public var createContainer: [OCIHook]
    public var startContainer: [OCIHook]
    public var poststart: [OCIHook]
    public var poststop: [OCIHook]

    public init(
        prestart: [OCIHook],
        createRuntime: [OCIHook],
        createContainer: [OCIHook],
        startContainer: [OCIHook],
        poststart: [OCIHook],
        poststop: [OCIHook]
    ) {
        self.prestart = prestart
        self.createRuntime = createRuntime
        self.createContainer = createContainer
        self.startContainer = startContainer
        self.poststart = poststart
        self.poststop = poststop
    }
}

public struct OCILinux: Codable, Sendable {
    public var uidMappings: [OCILinuxIDMapping]
    public var gidMappings: [OCILinuxIDMapping]
    public var sysctl: [String: String]?
    public var resources: OCILinuxResources?
    public var cgroupsPath: String
    public var namespaces: [OCILinuxNamespace]
    public var devices: [OCILinuxDevice]
    public var seccomp: OCILinuxSeccomp?
    public var rootfsPropagation: String
    public var maskedPaths: [String]
    public var readonlyPaths: [String]
    public var mountLabel: String
    public var personality: OCILinuxPersonality?

    public init(
        uidMappings: [OCILinuxIDMapping] = [],
        gidMappings: [OCILinuxIDMapping] = [],
        sysctl: [String: String]? = nil,
        resources: OCILinuxResources? = nil,
        cgroupsPath: String = "",
        namespaces: [OCILinuxNamespace] = [],
        devices: [OCILinuxDevice] = [],
        seccomp: OCILinuxSeccomp? = nil,
        rootfsPropagation: String = "",
        maskedPaths: [String] = [],
        readonlyPaths: [String] = [],
        mountLabel: String = "",
        personality: OCILinuxPersonality? = nil
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

public struct OCILinuxNamespace: Codable, Sendable {
    public var type: OCILinuxNamespaceType
    public var path: String

    public init(type: OCILinuxNamespaceType, path: String = "") {
        self.type = type
        self.path = path
    }
}

public enum OCILinuxNamespaceType: String, Codable, Sendable {
    case pid
    case network
    case uts
    case mount
    case ipc
    case user
    case cgroup
}

public struct OCILinuxIDMapping: Codable, Sendable {
    public var containerID: UInt32
    public var hostID: UInt32
    public var size: UInt32

    public init(containerID: UInt32, hostID: UInt32, size: UInt32) {
        self.containerID = containerID
        self.hostID = hostID
        self.size = size
    }
}

public struct OCIRlimit: Codable, Sendable {
    public var type: String
    public var hard: UInt64
    public var soft: UInt64

    public init(type: String, hard: UInt64, soft: UInt64) {
        self.type = type
        self.hard = hard
        self.soft = soft
    }
}

public struct OCILinuxHugepageLimit: Codable, Sendable {
    public var pagesize: String
    public var limit: UInt64

    public init(pagesize: String, limit: UInt64) {
        self.pagesize = pagesize
        self.limit = limit
    }
}

public struct OCILinuxInterfacePriority: Codable, Sendable {
    public var name: String
    public var priority: UInt32

    public init(name: String, priority: UInt32) {
        self.name = name
        self.priority = priority
    }
}

public struct OCILinuxBlockIODevice: Codable, Sendable {
    public var major: Int64
    public var minor: Int64

    public init(major: Int64, minor: Int64) {
        self.major = major
        self.minor = minor
    }
}

public struct OCILinuxWeightDevice: Codable, Sendable {
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

public struct OCILinuxThrottleDevice: Codable, Sendable {
    public var major: Int64
    public var minor: Int64
    public var rate: UInt64

    public init(major: Int64, minor: Int64, rate: UInt64) {
        self.major = major
        self.minor = minor
        self.rate = rate
    }
}

public struct OCILinuxBlockIO: Codable, Sendable {
    public var weight: UInt16?
    public var leafWeight: UInt16?
    public var weightDevice: [OCILinuxWeightDevice]
    public var throttleReadBpsDevice: [OCILinuxThrottleDevice]
    public var throttleWriteBpsDevice: [OCILinuxThrottleDevice]
    public var throttleReadIOPSDevice: [OCILinuxThrottleDevice]
    public var throttleWriteIOPSDevice: [OCILinuxThrottleDevice]

    public init(
        weight: UInt16?,
        leafWeight: UInt16?,
        weightDevice: [OCILinuxWeightDevice],
        throttleReadBpsDevice: [OCILinuxThrottleDevice],
        throttleWriteBpsDevice: [OCILinuxThrottleDevice],
        throttleReadIOPSDevice: [OCILinuxThrottleDevice],
        throttleWriteIOPSDevice: [OCILinuxThrottleDevice]
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

public struct OCILinuxMemory: Codable, Sendable {
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

public struct OCILinuxCPU: Codable, Sendable {
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

public struct OCILinuxPids: Codable, Sendable {
    public var limit: Int64

    public init(limit: Int64) {
        self.limit = limit
    }
}

public struct OCILinuxNetwork: Codable, Sendable {
    public var classID: UInt32?
    public var priorities: [OCILinuxInterfacePriority]

    public init(classID: UInt32?, priorities: [OCILinuxInterfacePriority]) {
        self.classID = classID
        self.priorities = priorities
    }
}

public struct OCILinuxRdma: Codable, Sendable {
    public var hcsHandles: UInt32?
    public var hcaObjects: UInt32?

    public init(hcsHandles: UInt32?, hcaObjects: UInt32?) {
        self.hcsHandles = hcsHandles
        self.hcaObjects = hcaObjects
    }
}

public struct OCILinuxResources: Codable, Sendable {
    public var devices: [OCILinuxDeviceCgroup]
    public var memory: OCILinuxMemory?
    public var cpu: OCILinuxCPU?
    public var pids: OCILinuxPids?
    public var blockIO: OCILinuxBlockIO?
    public var hugepageLimits: [OCILinuxHugepageLimit]
    public var network: OCILinuxNetwork?
    public var rdma: [String: OCILinuxRdma]?
    public var unified: [String: String]?

    public init(
        devices: [OCILinuxDeviceCgroup] = [],
        memory: OCILinuxMemory? = nil,
        cpu: OCILinuxCPU? = nil,
        pids: OCILinuxPids? = nil,
        blockIO: OCILinuxBlockIO? = nil,
        hugepageLimits: [OCILinuxHugepageLimit] = [],
        network: OCILinuxNetwork? = nil,
        rdma: [String: OCILinuxRdma]? = nil,
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

public struct OCILinuxDevice: Codable, Sendable {
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

public struct OCILinuxDeviceCgroup: Codable, Sendable {
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

public enum OCILinuxPersonalityDomain: String, Codable, Sendable {
    case perLinux = "LINUX"
    case perLinux32 = "LINUX32"
}

public struct OCILinuxPersonality: Codable, Sendable {
    public var domain: OCILinuxPersonalityDomain
    public var flags: [String]

    public init(domain: OCILinuxPersonalityDomain, flags: [String]) {
        self.domain = domain
        self.flags = flags
    }
}

public struct OCILinuxSeccomp: Codable, Sendable {
    public var defaultAction: OCILinuxSeccompAction
    public var defaultErrnoRet: UInt?
    public var architectures: [OCIArch]
    public var flags: [OCILinuxSeccompFlag]
    public var listenerPath: String
    public var listenerMetadata: String
    public var syscalls: [OCILinuxSyscall]

    public init(
        defaultAction: OCILinuxSeccompAction,
        defaultErrnoRet: UInt?,
        architectures: [OCIArch],
        flags: [OCILinuxSeccompFlag],
        listenerPath: String,
        listenerMetadata: String,
        syscalls: [OCILinuxSyscall]
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

public enum OCILinuxSeccompFlag: String, Codable, Sendable {
    case flagLog = "SECCOMP_FILTER_FLAG_LOG"
    case flagSpecAllow = "SECCOMP_FILTER_FLAG_SPEC_ALLOW"
    case flagWaitKillableRecv = "SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV"
}

public enum OCIArch: String, Codable, Sendable {
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

public enum OCILinuxSeccompAction: String, Codable, Sendable {
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

public enum OCILinuxSeccompOperator: String, Codable, Sendable {
    case opNotEqual = "SCMP_CMP_NE"
    case opLessThan = "SCMP_CMP_LT"
    case opLessEqual = "SCMP_CMP_LE"
    case opEqualTo = "SCMP_CMP_EQ"
    case opGreaterEqual = "SCMP_CMP_GE"
    case opGreaterThan = "SCMP_CMP_GT"
    case opMaskedEqual = "SCMP_CMP_MASKED_EQ"
}

public struct OCILinuxSeccompArg: Codable, Sendable {
    public var index: UInt
    public var value: UInt64
    public var valueTwo: UInt64
    public var op: OCILinuxSeccompOperator

    public init(index: UInt, value: UInt64, valueTwo: UInt64, op: OCILinuxSeccompOperator) {
        self.index = index
        self.value = value
        self.valueTwo = valueTwo
        self.op = op
    }
}

public struct OCILinuxSyscall: Codable, Sendable {
    public var names: [String]
    public var action: OCILinuxSeccompAction
    public var errnoRet: UInt?
    public var args: [OCILinuxSeccompArg]

    public init(
        names: [String],
        action: OCILinuxSeccompAction,
        errnoRet: UInt?,
        args: [OCILinuxSeccompArg]
    ) {
        self.names = names
        self.action = action
        self.errnoRet = errnoRet
        self.args = args
    }
}
