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

#if os(macOS)
import ContainerizationError
import ContainerizationExtras
import struct ContainerizationOS.Stat
import Foundation

struct VZUSBRootfsGuest: Sendable {
    struct Disk: Hashable, Sendable {
        let path: String
        let deviceNumber: UInt64
    }

    typealias Inventory = Set<Disk>

    static let paths = "abcdefghijklmnopqrstuvwxyz".map { "/dev/sd\($0)" }
    private static let pollInterval = Duration.milliseconds(125)
    private static let guestMounts = LinuxContainer.defaultMounts()
    private static let attachmentOptions: Set<Substring> = ["bind", "rbind", "move", "remount"]

    let agent: Vminitd

    static func isFilesystemMount(_ mount: Mount) -> Bool {
        mount.options.allSatisfy { attachmentOptions.isDisjoint(with: $0.split(separator: ",")) }
    }

    static func validateMount(_ mount: Mount) throws {
        guard case .any = mount.runtimeOptions, guestMounts.contains(where: { $0.type == mount.type && $0.source == mount.source }),
            isFilesystemMount(mount)
        else {
            throw ContainerizationError(.unsupported, message: "Rootfs hotplug requires source-free guest mounts")
        }
    }

    func inventory(checkDrivers: Bool = false) async throws -> Inventory {
        try await Timeout.run(seconds: 2) {
            if checkDrivers {
                for path in ["/sys/bus/pci/drivers/xhci_hcd", "/sys/bus/usb/drivers/usb-storage", "/sys/bus/scsi/drivers/sd"] {
                    guard try await stat(path) != nil else {
                        throw ContainerizationError(.unsupported, message: "USB rootfs hotplug requires xHCI PCI, USB storage and SCSI disk drivers (missing \(path))")
                    }
                }
            }
            var disks: Inventory = []
            for path in Self.paths {
                try Task.checkCancellation()
                if let info = try await stat(path), info.mode & 0o170000 == 0o060000 {
                    disks.insert(Disk(path: path, deviceNumber: info.rdev))
                }
            }
            guard try await stat("/dev/sdaa") == nil else {
                throw ContainerizationError(.unsupported, message: "guest SCSI disks exceed the supported range")
            }
            return disks
        }
    }

    func newDisk(after before: Inventory) async throws -> Disk {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        repeat {
            if let disk = try await additionalDisk(comparedWith: before) {
                return disk
            }
            try await clock.sleep(for: Self.pollInterval)
        } while clock.now < deadline
        throw ContainerizationError(.invalidState, message: "Linux did not enumerate the attached USB disk")
    }

    func confirmRemoval(of disk: Disk, leaving expected: Inventory) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        var stable = false

        repeat {
            let remaining = try await additionalDisk(comparedWith: expected)
            guard remaining == nil || remaining == disk else {
                throw ContainerizationError(.invalidState, message: "unexpected SCSI disk appeared during removal")
            }
            if remaining == nil && stable { return }
            stable = remaining == nil
            try await clock.sleep(for: Self.pollInterval)
        } while clock.now < deadline
        throw ContainerizationError(.invalidState, message: "Linux still reports a USB disk after host detach")
    }

    func verifyUnmounted(_ disk: Disk, containerID: String, canUnmount: Bool) async throws {
        try await Timeout.run(seconds: 4) {
            try await self.checkMount(disk, containerID: containerID, canUnmount: canUnmount)
        }
    }

    private func checkMount(_ disk: Disk, containerID: String, canUnmount: Bool) async throws {
        let containers = try await agent.containerStatistics(containerIDs: [], categories: .process)
        let container = containers.first { $0.id == containerID }
        if let container, container.process?.current != 0 {
            throw ContainerizationError(.invalidState, message: "Container \(containerID) still has live or unverified processes")
        }

        let path = LinuxPod.guestRootfsPath(containerID)
        let parent = URL(filePath: path).deletingLastPathComponent().path
        guard let mounted = try await stat(path) else {
            return
        }

        if mounted.dev == disk.deviceNumber {
            guard canUnmount, container == nil else {
                throw ContainerizationError(.invalidState, message: "Cannot safely unmount the rootfs for \(containerID)")
            }
            try await agent.umount(path: path, flags: 0)
        }

        // vminitd can acknowledge an unmount that is still busy. Compare the
        // mounted path and its parent so a foreign mount also blocks detach.
        if let current = try await stat(path) {
            guard current.dev != disk.deviceNumber, let owner = try await stat(parent),
                current.dev == owner.dev
            else {
                throw ContainerizationError(.invalidState, message: "Could not confirm rootfs unmount for \(containerID)")
            }
        }
    }

    private func stat(_ path: String) async throws -> Stat? {
        do {
            return try await agent.stat(root: "/", path: path)
        } catch let error as ContainerizationError where error.code == .notFound {
            return nil
        }
    }

    private func additionalDisk(comparedWith expected: Inventory) async throws -> Disk? {
        let observed = try await inventory()
        let added = observed.subtracting(expected)
        guard expected.isSubset(of: observed), added.count <= 1 else {
            throw ContainerizationError(.invalidState, message: "guest SCSI inventory changed unexpectedly")
        }
        let disk = added.first
        if let disk, expected.contains(where: { $0.deviceNumber == disk.deviceNumber }) {
            throw ContainerizationError(.invalidState, message: "guest SCSI node aliases an attached disk")
        }
        return disk
    }
}
#endif
