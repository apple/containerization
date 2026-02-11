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

// NOTE: Ideally this should live in ContainerizationOS/Linux, or just ContainerizationCgroups
// or something similar, but it's not there yet. It does what we need, but it'd need a lot more
// features and testing before it's ready to be public.

#if os(Linux)

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging

package enum Cgroup2Controller: String {
    case pids
    case memory
    case cpuset
    case cpu
    case io
    case hugetlb
}

// Extremely simple cgroup manager. Our needs are simple for now, and this is
// reflected in the type.
package struct Cgroup2Manager: Sendable {
    package static let defaultMountPoint = URL(filePath: "/sys/fs/cgroup")

    private static let killFile = "cgroup.kill"
    private static let procsFile = "cgroup.procs"
    private static let subtreeControlFile = "cgroup.subtree_control"

    private static let cg2Magic = 0x6367_7270

    private let mountPoint: URL
    private let path: URL
    private let logger: Logger?

    package init(
        mountPoint: URL = Self.defaultMountPoint,
        group: URL,
        logger: Logger? = nil
    ) {
        self.mountPoint = mountPoint
        self.path = mountPoint.appending(path: group.path)
        self.logger = logger
    }

    package static func load(
        mountPoint: URL = Self.defaultMountPoint,
        group: URL,
        logger: Logger? = nil
    ) throws -> Cgroup2Manager {
        let path = mountPoint.appending(path: group.path)
        var s = statfs()
        let res = statfs(path.path, &s)
        if res != 0 {
            throw Error.errno(errno: errno, message: "failed to statfs \(path.path)")
        }
        if Int64(s.f_type) != Self.cg2Magic {
            throw Error.notCgroup
        }
        return Cgroup2Manager(
            mountPoint: mountPoint,
            group: group,
            logger: logger
        )
    }

    package static func loadFromPid(pid: Int32, logger: Logger? = nil) throws -> Cgroup2Manager {
        let procCgPath = URL(filePath: "/proc/\(pid)/cgroup")
        let fh = try FileHandle(forReadingFrom: procCgPath)
        guard let data = try fh.readToEnd() else {
            throw Error.errno(errno: errno, message: "failed to read \(procCgPath)")
        }

        // If this fails we have bigger problems.
        let str = String(data: data, encoding: .utf8)!
        let parts = str.split(separator: ":")
        if parts[0] != "0" {
            throw Error.cgroup1
        }

        // We should really read /proc/pid/mountinfo, but for now just assume
        // it's always at /sys/fs/cgroup.
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return Cgroup2Manager(group: URL(filePath: String(path)), logger: logger)
    }

    package func create(perms: Int16 = 0o755) throws {
        self.logger?.info(
            "creating cgroup manager",
            metadata: [
                "mountpoint": "\(self.mountPoint.path)",
                "path": "\(self.path.path)",
            ])

        try FileManager.default.createDirectory(
            at: self.path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: perms]
        )
    }

    private static func writeValue(path: URL, value: String, fileName: String) throws {
        let file = path.appending(path: fileName)
        let fd = open(file.path, O_WRONLY, 0)
        if fd == -1 {
            throw Error.errno(errno: errno, message: "failed to open \(file.path)")
        }
        defer { close(fd) }

        let bytes = Array(value.utf8)
        let res = Syscall.retrying {
            bytes.withUnsafeBytes { write(fd, $0.baseAddress!, bytes.count) }
        }
        if res == -1 {
            throw Error.errno(errno: errno, message: "failed to write to \(file.path)")
        }
    }

    package func toggleSubtreeControllers(controllers: [Cgroup2Controller], enable: Bool) throws {
        let value = controllers.map { (enable ? "+" : "-") + $0.rawValue }.joined(separator: " ")
        let mountComponents = self.mountPoint.pathComponents
        let pathComponents = self.path.pathComponents

        // First ensure it's set on the root.
        var current = self.mountPoint
        try Self.writeValue(
            path: current,
            value: value,
            fileName: Self.subtreeControlFile
        )

        // Toggle everything except the leaf, as otherwise we won't be able to write
        // to cgroup.procs, and what fun is that :)
        if mountComponents.count < pathComponents.count - 1 {
            for i in mountComponents.count...pathComponents.count - 2 {
                current = current.appending(path: pathComponents[i])
                try Self.writeValue(
                    path: current,
                    value: value,
                    fileName: Self.subtreeControlFile
                )
            }
        }
    }

    package func toggleAllAvailableControllers(enable: Bool) throws {
        // Read available controllers from cgroup.controllers
        let controllersFile = self.mountPoint.appending(path: "cgroup.controllers")
        let controllersContent = try String(contentsOf: controllersFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse controller names and convert to our enum
        let availableControllers =
            controllersContent
            .split(separator: " ")
            .compactMap { Cgroup2Controller(rawValue: String($0)) }

        if !availableControllers.isEmpty {
            try toggleSubtreeControllers(controllers: availableControllers, enable: enable)
        }
    }

    package func addProcess(pid: Int32) throws {
        self.logger?.debug(
            "adding new proc to cgroup",
            metadata: [
                "mountpoint": "\(self.mountPoint.path)",
                "path": "\(self.path.path)",
            ])

        let pidStr = String(pid)
        try Self.writeValue(
            path: self.path,
            value: pidStr,
            fileName: Self.procsFile
        )
    }

    package func applyResources(resources: ContainerizationOCI.LinuxResources) throws {
        self.logger?.debug(
            "applying cgroup resources",
            metadata: [
                "path": "\(self.path.path)"
            ])

        if let memory = resources.memory, let limit = memory.limit {
            try Self.writeValue(
                path: self.path,
                value: String(limit),
                fileName: "memory.max"
            )
        }

        if let cpu = resources.cpu {
            if let quota = cpu.quota, let period = cpu.period {
                // cpu.max format is "quota period"
                let value = "\(quota) \(period)"
                try Self.writeValue(
                    path: self.path,
                    value: value,
                    fileName: "cpu.max"
                )
            }
        }

        if let pids = resources.pids {
            try Self.writeValue(
                path: self.path,
                value: String(pids.limit),
                fileName: "pids.max"
            )
        }
    }

    package func setMemoryHigh(bytes: UInt64) throws {
        self.logger?.debug(
            "setting memory.high",
            metadata: [
                "path": "\(self.path.path)",
                "bytes": "\(bytes)",
            ])

        try Self.writeValue(
            path: self.path,
            value: String(bytes),
            fileName: "memory.high"
        )
    }

    package func getMemoryEvents() throws -> MemoryEvents {
        let content = try readFileContent(fileName: "memory.events")
        let values = parseKeyValuePairs(content)

        return MemoryEvents(
            low: values["low"] ?? 0,
            high: values["high"] ?? 0,
            max: values["max"] ?? 0,
            oom: values["oom"] ?? 0,
            oomKill: values["oom_kill"] ?? 0
        )
    }

    package func getMemoryEventsPath() -> String {
        self.path.appending(path: "memory.events").path
    }

    package func kill() throws {
        try Self.writeValue(
            path: self.path,
            value: "1",
            fileName: Self.killFile
        )
    }

    package func delete(force: Bool = false) throws {
        self.logger?.info(
            "deleting cgroup manager",
            metadata: [
                "mountpoint": "\(self.mountPoint.path)",
                "path": "\(self.path.path)",
            ])

        if force {
            try self.kill()
        }

        // Recursively remove child cgroups first
        try removeChildCgroups(at: self.path, force: force)

        let result = rmdir(self.path.path)
        if result != 0 {
            throw Error.errno(errno: errno, message: "failed to remove cgroup directory \(self.path.path)")
        }
    }

    private func removeChildCgroups(at path: URL, force: Bool) throws {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(atPath: path.path) else {
            return
        }

        // Remove child directories (potential nested cgroups) first
        for item in contents {
            let childPath = path.appending(path: item)
            var isDirectory: ObjCBool = false

            if fileManager.fileExists(atPath: childPath.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                if force {
                    try Self.writeValue(
                        path: childPath,
                        value: "1",
                        fileName: Self.killFile
                    )
                }

                try removeChildCgroups(at: childPath, force: force)
                let result = rmdir(childPath.path)
                if result != 0 {
                    throw Error.errno(errno: errno, message: "failed to remove child cgroup \(childPath.path)")
                }
            }
        }
    }

    package func stats() throws -> Cgroup2Stats {
        let pidsStats = try self.readPidsStats()
        let memoryStats = try self.readMemoryStats()
        let cpuStats = try self.readCPUStats()
        let ioStats = try self.readIOStats()

        return Cgroup2Stats(
            pids: pidsStats,
            memory: memoryStats,
            cpu: cpuStats,
            io: ioStats
        )
    }

    private func readFileContent(fileName: String) throws -> String? {
        let filePath = self.path.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return nil
        }
        return try String(contentsOf: filePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseSingleValue(_ content: String?) -> UInt64? {
        guard let content = content, !content.isEmpty else { return nil }
        if content == "max" {
            return UInt64.max
        }
        return UInt64(content)
    }

    private func parseKeyValuePairs(_ content: String?) -> [String: UInt64] {
        guard let content = content else { return [:] }
        var result: [String: UInt64] = [:]

        for line in content.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces)
            if parts.count == 2, let value = UInt64(parts[1]) {
                result[parts[0]] = value
            }
        }
        return result
    }

    private func readPidsStats() throws -> PidsStats? {
        guard let currentContent = try readFileContent(fileName: "pids.current"),
            let current = parseSingleValue(currentContent)
        else {
            return nil
        }

        let maxContent = try readFileContent(fileName: "pids.max")
        let max = parseSingleValue(maxContent)

        return PidsStats(current: current, max: max)
    }

    private func readMemoryStats() throws -> MemoryStats? {
        guard let usageContent = try readFileContent(fileName: "memory.current"),
            let usage = parseSingleValue(usageContent)
        else {
            return nil
        }

        let usageLimit = parseSingleValue(try readFileContent(fileName: "memory.max"))
        let swapUsage = parseSingleValue(try readFileContent(fileName: "memory.swap.current"))
        let swapLimit = parseSingleValue(try readFileContent(fileName: "memory.swap.max"))

        let statContent = try readFileContent(fileName: "memory.stat")
        let statValues = parseKeyValuePairs(statContent)

        return MemoryStats(
            usage: usage,
            usageLimit: usageLimit,
            swapUsage: swapUsage,
            swapLimit: swapLimit,
            anon: statValues["anon"] ?? 0,
            file: statValues["file"] ?? 0,
            kernelStack: statValues["kernel_stack"] ?? 0,
            slab: statValues["slab"] ?? 0,
            sock: statValues["sock"] ?? 0,
            shmem: statValues["shmem"] ?? 0,
            fileMapped: statValues["file_mapped"] ?? 0,
            fileDirty: statValues["file_dirty"] ?? 0,
            fileWriteback: statValues["file_writeback"] ?? 0,
            pgfault: statValues["pgfault"] ?? 0,
            pgmajfault: statValues["pgmajfault"] ?? 0,
            workingsetRefault: statValues["workingset_refault"] ?? 0,
            workingsetActivate: statValues["workingset_activate"] ?? 0,
            workingsetNodereclaim: statValues["workingset_nodereclaim"] ?? 0,
            inactiveAnon: statValues["inactive_anon"] ?? 0,
            activeAnon: statValues["active_anon"] ?? 0,
            inactiveFile: statValues["inactive_file"] ?? 0,
            activeFile: statValues["active_file"] ?? 0
        )
    }

    private func readCPUStats() throws -> CPUStats? {
        let statContent = try readFileContent(fileName: "cpu.stat")
        let statValues = parseKeyValuePairs(statContent)

        guard !statValues.isEmpty else {
            return nil
        }

        return CPUStats(
            usageUsec: statValues["usage_usec"] ?? 0,
            userUsec: statValues["user_usec"] ?? 0,
            systemUsec: statValues["system_usec"] ?? 0,
            nrPeriods: statValues["nr_periods"] ?? 0,
            nrThrottled: statValues["nr_throttled"] ?? 0,
            throttledUsec: statValues["throttled_usec"] ?? 0
        )
    }

    private func readIOStats() throws -> IOStats? {
        guard let statContent = try readFileContent(fileName: "io.stat") else {
            return IOStats(entries: [])
        }

        var entries: [IOEntry] = []

        for line in statContent.components(separatedBy: .newlines) {
            guard !line.isEmpty else { continue }

            let parts = line.components(separatedBy: .whitespaces)
            guard parts.count >= 2 else { continue }

            let deviceParts = parts[0].components(separatedBy: ":")
            guard deviceParts.count == 2,
                let major = UInt64(deviceParts[0]),
                let minor = UInt64(deviceParts[1])
            else {
                continue
            }

            var rbytes: UInt64 = 0
            var wbytes: UInt64 = 0
            var rios: UInt64 = 0
            var wios: UInt64 = 0
            var dbytes: UInt64 = 0
            var dios: UInt64 = 0

            for i in 1..<parts.count {
                let keyValue = parts[i].components(separatedBy: "=")
                guard keyValue.count == 2, let value = UInt64(keyValue[1]) else { continue }

                switch keyValue[0] {
                case "rbytes":
                    rbytes = value
                case "wbytes":
                    wbytes = value
                case "rios":
                    rios = value
                case "wios":
                    wios = value
                case "dbytes":
                    dbytes = value
                case "dios":
                    dios = value
                default:
                    break
                }
            }

            entries.append(
                IOEntry(
                    major: major,
                    minor: minor,
                    rbytes: rbytes,
                    wbytes: wbytes,
                    rios: rios,
                    wios: wios,
                    dbytes: dbytes,
                    dios: dios
                ))
        }

        return IOStats(entries: entries)
    }
}

package struct Cgroup2Stats: Sendable {
    package var pids: PidsStats?
    package var memory: MemoryStats?
    package var cpu: CPUStats?
    package var io: IOStats?

    package init(
        pids: PidsStats? = nil,
        memory: MemoryStats? = nil,
        cpu: CPUStats? = nil,
        io: IOStats? = nil
    ) {
        self.pids = pids
        self.memory = memory
        self.cpu = cpu
        self.io = io
    }
}

package struct PidsStats: Sendable {
    package var current: UInt64
    package var max: UInt64?

    package init(current: UInt64, max: UInt64? = nil) {
        self.current = current
        self.max = max
    }
}

package struct MemoryStats: Sendable {
    package var usage: UInt64
    package var usageLimit: UInt64?
    package var swapUsage: UInt64?
    package var swapLimit: UInt64?

    package var anon: UInt64
    package var file: UInt64
    package var kernelStack: UInt64
    package var slab: UInt64
    package var sock: UInt64
    package var shmem: UInt64
    package var fileMapped: UInt64
    package var fileDirty: UInt64
    package var fileWriteback: UInt64

    package var pgfault: UInt64
    package var pgmajfault: UInt64

    package var workingsetRefault: UInt64
    package var workingsetActivate: UInt64
    package var workingsetNodereclaim: UInt64

    package var inactiveAnon: UInt64
    package var activeAnon: UInt64
    package var inactiveFile: UInt64
    package var activeFile: UInt64

    package init(
        usage: UInt64,
        usageLimit: UInt64? = nil,
        swapUsage: UInt64? = nil,
        swapLimit: UInt64? = nil,
        anon: UInt64 = 0,
        file: UInt64 = 0,
        kernelStack: UInt64 = 0,
        slab: UInt64 = 0,
        sock: UInt64 = 0,
        shmem: UInt64 = 0,
        fileMapped: UInt64 = 0,
        fileDirty: UInt64 = 0,
        fileWriteback: UInt64 = 0,
        pgfault: UInt64 = 0,
        pgmajfault: UInt64 = 0,
        workingsetRefault: UInt64 = 0,
        workingsetActivate: UInt64 = 0,
        workingsetNodereclaim: UInt64 = 0,
        inactiveAnon: UInt64 = 0,
        activeAnon: UInt64 = 0,
        inactiveFile: UInt64 = 0,
        activeFile: UInt64 = 0
    ) {
        self.usage = usage
        self.usageLimit = usageLimit
        self.swapUsage = swapUsage
        self.swapLimit = swapLimit
        self.anon = anon
        self.file = file
        self.kernelStack = kernelStack
        self.slab = slab
        self.sock = sock
        self.shmem = shmem
        self.fileMapped = fileMapped
        self.fileDirty = fileDirty
        self.fileWriteback = fileWriteback
        self.pgfault = pgfault
        self.pgmajfault = pgmajfault
        self.workingsetRefault = workingsetRefault
        self.workingsetActivate = workingsetActivate
        self.workingsetNodereclaim = workingsetNodereclaim
        self.inactiveAnon = inactiveAnon
        self.activeAnon = activeAnon
        self.inactiveFile = inactiveFile
        self.activeFile = activeFile
    }
}

package struct CPUStats: Sendable {
    package var usageUsec: UInt64
    package var userUsec: UInt64
    package var systemUsec: UInt64
    package var nrPeriods: UInt64
    package var nrThrottled: UInt64
    package var throttledUsec: UInt64

    package init(
        usageUsec: UInt64 = 0,
        userUsec: UInt64 = 0,
        systemUsec: UInt64 = 0,
        nrPeriods: UInt64 = 0,
        nrThrottled: UInt64 = 0,
        throttledUsec: UInt64 = 0
    ) {
        self.usageUsec = usageUsec
        self.userUsec = userUsec
        self.systemUsec = systemUsec
        self.nrPeriods = nrPeriods
        self.nrThrottled = nrThrottled
        self.throttledUsec = throttledUsec
    }
}

package struct IOStats: Sendable {
    package var entries: [IOEntry]

    package init(entries: [IOEntry] = []) {
        self.entries = entries
    }
}

package struct IOEntry: Sendable {
    package var major: UInt64
    package var minor: UInt64
    package var rbytes: UInt64
    package var wbytes: UInt64
    package var rios: UInt64
    package var wios: UInt64
    package var dbytes: UInt64
    package var dios: UInt64

    package init(
        major: UInt64,
        minor: UInt64,
        rbytes: UInt64 = 0,
        wbytes: UInt64 = 0,
        rios: UInt64 = 0,
        wios: UInt64 = 0,
        dbytes: UInt64 = 0,
        dios: UInt64 = 0
    ) {
        self.major = major
        self.minor = minor
        self.rbytes = rbytes
        self.wbytes = wbytes
        self.rios = rios
        self.wios = wios
        self.dbytes = dbytes
        self.dios = dios
    }
}

package struct MemoryEvents: Sendable {
    package var low: UInt64
    package var high: UInt64
    package var max: UInt64
    package var oom: UInt64
    package var oomKill: UInt64

    package init(
        low: UInt64 = 0,
        high: UInt64 = 0,
        max: UInt64 = 0,
        oom: UInt64 = 0,
        oomKill: UInt64 = 0
    ) {
        self.low = low
        self.high = high
        self.max = max
        self.oom = oom
        self.oomKill = oomKill
    }
}

extension Cgroup2Manager {
    package enum Error: Swift.Error, CustomStringConvertible {
        case notCgroup
        case cgroup1
        case errno(errno: Int32, message: String)
        case notExist(path: String)

        package var description: String {
            switch self {
            case .errno(let errno, let message):
                return "failed with errno \(errno): \(message)"
            case .notExist(let path):
                return "cgroup at path \(path) does not exist"
            case .cgroup1:
                return "tried to load a cgroup v1 path"
            case .notCgroup:
                return "path is not a cgroup mountpoint"
            }
        }
    }
}

#endif
