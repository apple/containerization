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

import CShim
import Foundation

// MARK: - Configuration Types

public struct CapabilitySet: Sendable, Hashable {
    private enum Value: Hashable, Sendable, CaseIterable {
        case bounding
        case effective
        case inheritable
        case permitted
        case ambient
    }

    private var value: Value
    private init(_ value: Value) {
        self.value = value
    }

    public init(rawValue: String) {
        let values = Value.allCases.reduce(into: [String: Value]()) {
            $0[String(describing: $1)] = $1
        }

        let match = values[rawValue]
        guard let match else {
            fatalError("invalid CapabilitySet Value \(rawValue)")
        }
        self.value = match
    }

    public static var bounding: Self { Self(.bounding) }
    public static var effective: Self { Self(.effective) }
    public static var inheritable: Self { Self(.inheritable) }
    public static var permitted: Self { Self(.permitted) }
    public static var ambient: Self { Self(.ambient) }
}

extension CapabilitySet: CustomStringConvertible {
    public var description: String {
        String(describing: self.value)
    }
}

public struct CapabilityName: Sendable, Hashable {
    private enum Value: Hashable, Sendable, CaseIterable {
        case chown
        case dacOverride
        case dacReadSearch
        case fowner
        case fsetid
        case kill
        case setgid
        case setuid
        case setpcap
        case linuxImmutable
        case netBindService
        case netBroadcast
        case netAdmin
        case netRaw
        case ipcLock
        case ipcOwner
        case sysModule
        case sysRawio
        case sysChroot
        case sysPtrace
        case sysPacct
        case sysAdmin
        case sysBoot
        case sysNice
        case sysResource
        case sysTime
        case sysTtyConfig
        case mknod
        case lease
        case auditWrite
        case auditControl
        case setfcap
        case macOverride
        case macAdmin
        case syslog
        case wakeAlarm
        case blockSuspend
        case auditRead
        case perfmon
        case bpf
        case checkpointRestore
    }

    private var value: Value
    private init(_ value: Value) {
        self.value = value
    }

    public init(rawValue: String) {
        let normalized = rawValue.hasPrefix("CAP_") ? rawValue : "CAP_\(rawValue)"

        let capNameMap: [String: Value] = [
            "CAP_CHOWN": .chown,
            "CAP_DAC_OVERRIDE": .dacOverride,
            "CAP_DAC_READ_SEARCH": .dacReadSearch,
            "CAP_FOWNER": .fowner,
            "CAP_FSETID": .fsetid,
            "CAP_KILL": .kill,
            "CAP_SETGID": .setgid,
            "CAP_SETUID": .setuid,
            "CAP_SETPCAP": .setpcap,
            "CAP_LINUX_IMMUTABLE": .linuxImmutable,
            "CAP_NET_BIND_SERVICE": .netBindService,
            "CAP_NET_BROADCAST": .netBroadcast,
            "CAP_NET_ADMIN": .netAdmin,
            "CAP_NET_RAW": .netRaw,
            "CAP_IPC_LOCK": .ipcLock,
            "CAP_IPC_OWNER": .ipcOwner,
            "CAP_SYS_MODULE": .sysModule,
            "CAP_SYS_RAWIO": .sysRawio,
            "CAP_SYS_CHROOT": .sysChroot,
            "CAP_SYS_PTRACE": .sysPtrace,
            "CAP_SYS_PACCT": .sysPacct,
            "CAP_SYS_ADMIN": .sysAdmin,
            "CAP_SYS_BOOT": .sysBoot,
            "CAP_SYS_NICE": .sysNice,
            "CAP_SYS_RESOURCE": .sysResource,
            "CAP_SYS_TIME": .sysTime,
            "CAP_SYS_TTY_CONFIG": .sysTtyConfig,
            "CAP_MKNOD": .mknod,
            "CAP_LEASE": .lease,
            "CAP_AUDIT_WRITE": .auditWrite,
            "CAP_AUDIT_CONTROL": .auditControl,
            "CAP_SETFCAP": .setfcap,
            "CAP_MAC_OVERRIDE": .macOverride,
            "CAP_MAC_ADMIN": .macAdmin,
            "CAP_SYSLOG": .syslog,
            "CAP_WAKE_ALARM": .wakeAlarm,
            "CAP_BLOCK_SUSPEND": .blockSuspend,
            "CAP_AUDIT_READ": .auditRead,
            "CAP_PERFMON": .perfmon,
            "CAP_BPF": .bpf,
            "CAP_CHECKPOINT_RESTORE": .checkpointRestore,
        ]

        guard let match = capNameMap[normalized] else {
            fatalError("invalid CapabilityName \(normalized)")
        }
        self.value = match
    }

    public var capValue: UInt32 {
        switch self.value {
        case .chown: return 0
        case .dacOverride: return 1
        case .dacReadSearch: return 2
        case .fowner: return 3
        case .fsetid: return 4
        case .kill: return 5
        case .setgid: return 6
        case .setuid: return 7
        case .setpcap: return 8
        case .linuxImmutable: return 9
        case .netBindService: return 10
        case .netBroadcast: return 11
        case .netAdmin: return 12
        case .netRaw: return 13
        case .ipcLock: return 14
        case .ipcOwner: return 15
        case .sysModule: return 16
        case .sysRawio: return 17
        case .sysChroot: return 18
        case .sysPtrace: return 19
        case .sysPacct: return 20
        case .sysAdmin: return 21
        case .sysBoot: return 22
        case .sysNice: return 23
        case .sysResource: return 24
        case .sysTime: return 25
        case .sysTtyConfig: return 26
        case .mknod: return 27
        case .lease: return 28
        case .auditWrite: return 29
        case .auditControl: return 30
        case .setfcap: return 31
        case .macOverride: return 32
        case .macAdmin: return 33
        case .syslog: return 34
        case .wakeAlarm: return 35
        case .blockSuspend: return 36
        case .auditRead: return 37
        case .perfmon: return 38
        case .bpf: return 39
        case .checkpointRestore: return 40
        }
    }

    public static var chown: Self { Self(.chown) }
    public static var dacOverride: Self { Self(.dacOverride) }
    public static var dacReadSearch: Self { Self(.dacReadSearch) }
    public static var fowner: Self { Self(.fowner) }
    public static var fsetid: Self { Self(.fsetid) }
    public static var kill: Self { Self(.kill) }
    public static var setgid: Self { Self(.setgid) }
    public static var setuid: Self { Self(.setuid) }
    public static var setpcap: Self { Self(.setpcap) }
    public static var linuxImmutable: Self { Self(.linuxImmutable) }
    public static var netBindService: Self { Self(.netBindService) }
    public static var netBroadcast: Self { Self(.netBroadcast) }
    public static var netAdmin: Self { Self(.netAdmin) }
    public static var netRaw: Self { Self(.netRaw) }
    public static var ipcLock: Self { Self(.ipcLock) }
    public static var ipcOwner: Self { Self(.ipcOwner) }
    public static var sysModule: Self { Self(.sysModule) }
    public static var sysRawio: Self { Self(.sysRawio) }
    public static var sysChroot: Self { Self(.sysChroot) }
    public static var sysPtrace: Self { Self(.sysPtrace) }
    public static var sysPacct: Self { Self(.sysPacct) }
    public static var sysAdmin: Self { Self(.sysAdmin) }
    public static var sysBoot: Self { Self(.sysBoot) }
    public static var sysNice: Self { Self(.sysNice) }
    public static var sysResource: Self { Self(.sysResource) }
    public static var sysTime: Self { Self(.sysTime) }
    public static var sysTtyConfig: Self { Self(.sysTtyConfig) }
    public static var mknod: Self { Self(.mknod) }
    public static var lease: Self { Self(.lease) }
    public static var auditWrite: Self { Self(.auditWrite) }
    public static var auditControl: Self { Self(.auditControl) }
    public static var setfcap: Self { Self(.setfcap) }
    public static var macOverride: Self { Self(.macOverride) }
    public static var macAdmin: Self { Self(.macAdmin) }
    public static var syslog: Self { Self(.syslog) }
    public static var wakeAlarm: Self { Self(.wakeAlarm) }
    public static var blockSuspend: Self { Self(.blockSuspend) }
    public static var auditRead: Self { Self(.auditRead) }
    public static var perfmon: Self { Self(.perfmon) }
    public static var bpf: Self { Self(.bpf) }
    public static var checkpointRestore: Self { Self(.checkpointRestore) }

    public static var allCases: [CapabilityName] {
        Value.allCases.map { CapabilityName($0) }
    }
}

extension CapabilityName: CustomStringConvertible {
    public var description: String {
        switch self.value {
        case .chown: return "CAP_CHOWN"
        case .dacOverride: return "CAP_DAC_OVERRIDE"
        case .dacReadSearch: return "CAP_DAC_READ_SEARCH"
        case .fowner: return "CAP_FOWNER"
        case .fsetid: return "CAP_FSETID"
        case .kill: return "CAP_KILL"
        case .setgid: return "CAP_SETGID"
        case .setuid: return "CAP_SETUID"
        case .setpcap: return "CAP_SETPCAP"
        case .linuxImmutable: return "CAP_LINUX_IMMUTABLE"
        case .netBindService: return "CAP_NET_BIND_SERVICE"
        case .netBroadcast: return "CAP_NET_BROADCAST"
        case .netAdmin: return "CAP_NET_ADMIN"
        case .netRaw: return "CAP_NET_RAW"
        case .ipcLock: return "CAP_IPC_LOCK"
        case .ipcOwner: return "CAP_IPC_OWNER"
        case .sysModule: return "CAP_SYS_MODULE"
        case .sysRawio: return "CAP_SYS_RAWIO"
        case .sysChroot: return "CAP_SYS_CHROOT"
        case .sysPtrace: return "CAP_SYS_PTRACE"
        case .sysPacct: return "CAP_SYS_PACCT"
        case .sysAdmin: return "CAP_SYS_ADMIN"
        case .sysBoot: return "CAP_SYS_BOOT"
        case .sysNice: return "CAP_SYS_NICE"
        case .sysResource: return "CAP_SYS_RESOURCE"
        case .sysTime: return "CAP_SYS_TIME"
        case .sysTtyConfig: return "CAP_SYS_TTY_CONFIG"
        case .mknod: return "CAP_MKNOD"
        case .lease: return "CAP_LEASE"
        case .auditWrite: return "CAP_AUDIT_WRITE"
        case .auditControl: return "CAP_AUDIT_CONTROL"
        case .setfcap: return "CAP_SETFCAP"
        case .macOverride: return "CAP_MAC_OVERRIDE"
        case .macAdmin: return "CAP_MAC_ADMIN"
        case .syslog: return "CAP_SYSLOG"
        case .wakeAlarm: return "CAP_WAKE_ALARM"
        case .blockSuspend: return "CAP_BLOCK_SUSPEND"
        case .auditRead: return "CAP_AUDIT_READ"
        case .perfmon: return "CAP_PERFMON"
        case .bpf: return "CAP_BPF"
        case .checkpointRestore: return "CAP_CHECKPOINT_RESTORE"
        }
    }
}

// MARK: - Linux Implementation

#if os(Linux)

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

import CShim

/// Capability type flags
public struct CapType: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // Individual capability sets (for Get/Set/Unset/etc)
    public static let effective = CapType(rawValue: 1 << 0)
    public static let permitted = CapType(rawValue: 1 << 1)
    public static let inheritable = CapType(rawValue: 1 << 2)
    public static let bounding = CapType(rawValue: 1 << 3)
    public static let ambient = CapType(rawValue: 1 << 4)

    // Bulk operation flags (for Apply/Fill/Clear)
    public static let caps = CapType(rawValue: 1 << 8)  // CAPS - effective, permitted, inheritable
    public static let bounds = CapType(rawValue: 1 << 9)  // BOUNDS - bounding set
    public static let ambs = CapType(rawValue: 1 << 10)  // AMBS - ambient capabilities
}

private struct CapabilityHeader {
    var version: UInt32
    var pid: Int32

    init(pid: Int32 = 0) {
        self.version = 0x2008_0522
        self.pid = pid
    }
}

private struct CapabilityData {
    var effective1: UInt32
    var permitted1: UInt32
    var inheritable1: UInt32
    var effective2: UInt32
    var permitted2: UInt32
    var inheritable2: UInt32

    init(
        effective1: UInt32 = 0,
        permitted1: UInt32 = 0,
        inheritable1: UInt32 = 0,
        effective2: UInt32 = 0,
        permitted2: UInt32 = 0,
        inheritable2: UInt32 = 0
    ) {
        self.effective1 = effective1
        self.permitted1 = permitted1
        self.inheritable1 = inheritable1
        self.effective2 = effective2
        self.permitted2 = permitted2
        self.inheritable2 = inheritable2
    }
}

/// Interface with Linux capabilities
/// https://linux.die.net/man/7/capabilities
public struct LinuxCapabilities: Sendable {
    private var effectiveSet: UInt64 = 0
    private var permittedSet: UInt64 = 0
    private var inheritableSet: UInt64 = 0
    private var boundingSet: UInt64 = 0
    private var ambientSet: UInt64 = 0

    public init() {}

    /// Get the highest supported capability from the kernel
    public static func getLastSupported() throws -> CapabilityName {
        guard let data = try? String(contentsOfFile: "/proc/sys/kernel/cap_last_cap", encoding: .ascii),
            let lastCap = UInt32(data.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw LinuxCapabilities.Error.invalidCapabilitySet("failed to read /proc/sys/kernel/cap_last_cap")
        }

        guard let capability = CapabilityName.allCases.first(where: { $0.capValue == lastCap }) else {
            throw LinuxCapabilities.Error.invalidCapabilitySet("no capability found for kernel max cap \(lastCap)")
        }

        return capability
    }

    /// Set keep caps
    public static func setKeepCaps() throws {
        let result = CZ_prctl_set_keepcaps()
        if result != 0 {
            throw LinuxCapabilities.Error.prctlFailed(errno: errno, operation: "PR_SET_KEEPCAPS")
        }
    }

    /// Clear keep caps
    public static func clearKeepCaps() throws {
        let result = CZ_prctl_clear_keepcaps()
        if result != 0 {
            throw LinuxCapabilities.Error.prctlFailed(errno: errno, operation: "PR_CLEAR_KEEPCAPS")
        }
    }

    /// Load current process capabilities from kernel
    public mutating func load() throws {
        let data = try getCurrentCapabilities()
        self.effectiveSet = UInt64(data.effective1)
        self.permittedSet = UInt64(data.permitted1)
        self.inheritableSet = UInt64(data.inheritable1)
    }

    /// Check if capability is present in the given set
    public func get(which: CapType, what: CapabilityName) -> Bool {
        let bit = UInt64(1) << what.capValue

        if which.contains(.effective) {
            return (effectiveSet & bit) != 0
        } else if which.contains(.permitted) {
            return (permittedSet & bit) != 0
        } else if which.contains(.inheritable) {
            return (inheritableSet & bit) != 0
        } else if which.contains(.bounding) {
            return (boundingSet & bit) != 0
        } else if which.contains(.ambient) {
            return (ambientSet & bit) != 0
        }
        return false
    }

    /// Set capabilities in the given sets
    public mutating func set(which: CapType, caps: [CapabilityName]) {
        let mask = caps.reduce(UInt64(0)) { result, cap in
            result | (UInt64(1) << cap.capValue)
        }

        if which.contains(.effective) {
            effectiveSet |= mask
        }
        if which.contains(.permitted) {
            permittedSet |= mask
        }
        if which.contains(.inheritable) {
            inheritableSet |= mask
        }
        if which.contains(.bounding) {
            boundingSet |= mask
        }
        if which.contains(.ambient) {
            ambientSet |= mask
        }
    }

    /// Unset capabilities from the given sets
    public mutating func unset(which: CapType, caps: [CapabilityName]) {
        let mask = caps.reduce(UInt64(0)) { result, cap in
            result | (UInt64(1) << cap.capValue)
        }

        if which.contains(.effective) {
            effectiveSet &= ~mask
        }
        if which.contains(.permitted) {
            permittedSet &= ~mask
        }
        if which.contains(.inheritable) {
            inheritableSet &= ~mask
        }
        if which.contains(.bounding) {
            boundingSet &= ~mask
        }
        if which.contains(.ambient) {
            ambientSet &= ~mask
        }
    }

    /// Fill all bits of given capability types
    public mutating func fill(kind: CapType) {
        if kind.contains(.caps) {
            effectiveSet = 0xFFFF_FFFF_FFFF_FFFF
            permittedSet = 0xFFFF_FFFF_FFFF_FFFF
            inheritableSet = 0
        }
        if kind.contains(.bounds) {
            boundingSet = 0xFFFF_FFFF_FFFF_FFFF
        }
        if kind.contains(.ambs) {
            ambientSet = 0xFFFF_FFFF_FFFF_FFFF
        }
    }

    /// Clear all bits of given capability types
    public mutating func clear(kind: CapType) {
        if kind.contains(.caps) {
            effectiveSet = 0
            permittedSet = 0
            inheritableSet = 0
        }
        if kind.contains(.bounds) {
            boundingSet = 0
        }
        if kind.contains(.ambs) {
            ambientSet = 0
        }
    }

    /// Apply capabilities to current process
    public func apply(kind: CapType) throws {
        // Apply bounding set (requires CAP_SETPCAP)
        if kind.contains(.bounds) {
            try applyBoundingSet()
        }

        // Apply main capabilities (effective, permitted, inheritable)
        if kind.contains(.caps) {
            try applyMainCapabilities()
        }

        // Apply ambient capabilities
        if kind.contains(.ambs) {
            try applyAmbientCapabilities()
        }
    }

    private func applyBoundingSet() throws {
        let currentData = try getCurrentCapabilities()
        let hasSetPCap = (currentData.effective1 & (1 << CapabilityName.setpcap.capValue)) != 0

        if hasSetPCap {
            // Get the last supported capability to avoid trying to drop unsupported ones
            let lastSupported = try Self.getLastSupported()

            for cap in CapabilityName.allCases {
                // Skip capabilities higher than what the kernel supports
                guard cap.capValue <= lastSupported.capValue else { continue }

                let capBit = UInt64(1) << cap.capValue
                if (boundingSet & capBit) == 0 {
                    let result = CZ_prctl_capbset_drop(cap.capValue)
                    if result != 0 && errno != EINVAL {
                        throw Error.prctlFailed(errno: errno, operation: "PR_CAPBSET_DROP")
                    }
                }
            }
        }
    }

    private func applyMainCapabilities() throws {
        let data = CapabilityData(
            effective1: UInt32(effectiveSet & 0xFFFF_FFFF),
            permitted1: UInt32(permittedSet & 0xFFFF_FFFF),
            inheritable1: UInt32(inheritableSet & 0xFFFF_FFFF)
        )

        try setCapabilities(data: data)
    }

    private func applyAmbientCapabilities() throws {
        // Clear all ambient capabilities first
        let clearResult = CZ_prctl_cap_ambient_clear_all()
        if clearResult != 0 && errno != EINVAL {
            throw Error.prctlFailed(errno: errno, operation: "PR_CAP_AMBIENT_CLEAR_ALL")
        }

        // Get the last supported capability to avoid trying to set unsupported ones
        let lastSupported = try Self.getLastSupported()

        // Set each ambient capability
        for cap in CapabilityName.allCases {
            // Skip capabilities higher than what the kernel supports
            guard cap.capValue <= lastSupported.capValue else { continue }

            let capBit = UInt64(1) << cap.capValue
            if (ambientSet & capBit) != 0 {
                let result = CZ_prctl_cap_ambient_raise(cap.capValue)
                if result != 0 && errno != EINVAL {
                    throw Error.prctlFailed(errno: errno, operation: "PR_CAP_AMBIENT_RAISE")
                }
            }
        }
    }

    private func getCurrentCapabilities() throws -> CapabilityData {
        var header = CapabilityHeader()
        var data = CapabilityData()

        let result = withUnsafeMutablePointer(to: &header) { headerPtr in
            withUnsafeMutablePointer(to: &data) { dataPtr in
                CZ_capget(headerPtr, dataPtr)
            }
        }

        if result != 0 {
            throw Error.capgetFailed(errno: errno)
        }

        return data
    }

    private func setCapabilities(data: CapabilityData) throws {
        var header = CapabilityHeader()
        var mutableData = data

        let result = withUnsafeMutablePointer(to: &header) { headerPtr in
            withUnsafeMutablePointer(to: &mutableData) { dataPtr in
                CZ_capset(headerPtr, dataPtr)
            }
        }

        if result != 0 {
            throw Error.capsetFailed(errno: errno)
        }
    }
}

extension LinuxCapabilities {
    public enum Error: Swift.Error, CustomStringConvertible {
        case unsupportedCapability(name: String)
        case capsetFailed(errno: Int32)
        case capgetFailed(errno: Int32)
        case prctlFailed(errno: Int32, operation: String)
        case invalidCapabilitySet(String)

        public var description: String {
            switch self {
            case .unsupportedCapability(let name):
                return "unsupported capability: \(name)"
            case .capsetFailed(let errno):
                return "capset failed with errno \(errno): \(String(cString: strerror(errno)))"
            case .capgetFailed(let errno):
                return "capget failed with errno \(errno): \(String(cString: strerror(errno)))"
            case .prctlFailed(let errno, let operation):
                return "prctl(\(operation)) failed with errno \(errno): \(String(cString: strerror(errno)))"
            case .invalidCapabilitySet(let message):
                return "invalid capability set configuration: \(message)"
            }
        }
    }
}

#endif
