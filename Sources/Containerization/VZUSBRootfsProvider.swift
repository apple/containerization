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
import Foundation

final class VZUSBRootfsProvider: HotplugProvider {
    private struct Attachment: Sendable {
        let usb: VZUSBStorage
        let image: VZDiskImageID
        var disk: VZUSBRootfsGuest.Disk?
        var releasing = false
    }

    private let instance: @Sendable () -> VZVirtualMachineInstance?
    private let reserved: Set<VZDiskImageID>
    private let attachments = AsyncMutex<[String: Attachment]>([:])

    init(instance: VZVirtualMachineInstance, reserved: Set<VZDiskImageID>) {
        self.instance = { [weak instance] in instance }
        self.reserved = reserved
    }

    func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        try Self.validateID(id)
        guard block.type == "ext4", case .virtioblk(let options) = block.runtimeOptions,
            block.destination.isEmpty || block.destination == "/", block.source.hasPrefix("/"), VZUSBRootfsGuest.isFilesystemMount(block), !block.options.contains("ro")
        else {
            throw ContainerizationError(.unsupported, message: "USB rootfs hotplug requires a local writable ext4 rootfs")
        }
        let image = try VZDiskImageID(URL(filePath: block.source))

        return try await attachments.withLock { owned in
            try Task.checkCancellation()
            if let pending = owned.first(where: { $0.value.releasing }) {
                throw Self.cleanupRequired(pending.key)
            }
            guard let instance = self.instance() else {
                throw ContainerizationError(.invalidState, message: "The hotplug VM is gone")
            }
            guard owned[id] == nil, instance.mounts[id] == nil else {
                throw ContainerizationError(.exists, message: "Container \(id) already owns a rootfs")
            }
            guard !self.reserved.contains(image), !owned.values.contains(where: { $0.image == image }) else {
                throw ContainerizationError(.exists, message: "The writable rootfs image is already attached")
            }
            guard owned.count < VZUSBRootfsGuest.paths.count else {
                throw ContainerizationError(.unsupported, message: "The guest SCSI disk range is full")
            }

            let ownedUSB = Set(owned.values.map { $0.usb.id })
            let ownedGuest = Set(owned.values.compactMap(\.disk))
            try VZUSBStorage.verifyDevices(ownedUSB, in: instance)

            do {
                let rootfs = try await Self.withGuest(in: instance) { guest in
                    guard try await guest.inventory(checkDrivers: true) == ownedGuest else {
                        throw ContainerizationError(.invalidState, message: "Guest SCSI devices differ from the provider's owned disks")
                    }
                    try Task.checkCancellation()
                    let device = try VZUSBStorage(block, options: options, in: instance)
                    // Track the handle before attach so even an ambiguous callback
                    // failure can be reconciled by its host UUID.
                    owned[id] = Attachment(usb: device, image: image)
                    do {
                        try await device.change(.attach, alongside: ownedUSB, in: instance)
                    } catch {
                        // VZ can reject an attachment before taking the device. Keep tracking it
                        // if its absence cannot be confirmed.
                        if (try? device.isAttached(alongside: ownedUSB, in: instance)) == false {
                            owned.removeValue(forKey: id)
                        }
                        throw error
                    }
                    let disk = try await guest.newDisk(after: ownedGuest)
                    owned[id]?.disk = disk
                    try VZUSBStorage.verifyDevices(ownedUSB.union([device.id]), in: instance)
                    return AttachedFilesystem(
                        type: block.type,
                        source: disk.path,
                        destination: block.destination,
                        options: block.options
                    )
                }
                try Task.checkCancellation()
                return rootfs
            } catch {
                do {
                    try await Self.release(id: id, from: &owned, in: instance)
                } catch let cleanupError {
                    throw Self.cleanupRequired(id, cause: cleanupError)
                }
                throw error
            }
        }
    }

    func registerMounts(id: String, rootfs: AttachedFilesystem, additionalMounts: [Mount]) throws {
        try Self.validateID(id)
        guard let instance = instance() else {
            throw ContainerizationError(.invalidState, message: "The hotplug VM is gone")
        }
        let guestMounts = try additionalMounts.map { mount in
            try VZUSBRootfsGuest.validateMount(mount)
            return AttachedFilesystem(
                type: mount.type,
                source: mount.source,
                destination: mount.destination,
                options: mount.options
            )
        }
        try instance.withMountRegistry { registry in
            guard registry[id] == nil else {
                throw ContainerizationError(.exists, message: "Mounts already exist for container \(id)")
            }
            registry[id] = [rootfs] + guestMounts
        }
    }

    func releaseHotplug(id: String) async throws {
        try await attachments.withLock { owned in
            guard let instance = self.instance() else { return }
            try await Self.release(id: id, from: &owned, in: instance)
        }
    }

    func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        guard mounts.isEmpty else {
            throw ContainerizationError(.unsupported, message: "This provider hotplugs only the ext4 rootfs")
        }
    }

    func releaseVirtioFS(id: String) async throws {}

    private static func release(
        id: String,
        from owned: inout [String: Attachment],
        in instance: VZVirtualMachineInstance
    ) async throws {
        guard let attachment = owned[id] else { return }
        let remaining = owned.filter { $0.key != id }
        if let pending = remaining.first(where: { $0.value.releasing }) {
            throw cleanupRequired(pending.key)
        }

        owned[id]?.releasing = true
        let otherUSB = Set(remaining.values.map { $0.usb.id })
        let otherDisks = Set(remaining.values.compactMap(\.disk))
        // Unstructured work lets the cleanup finish even if the caller's task
        // was cancelled after the VZ attach or during guest enumeration.
        let disk: VZUSBRootfsGuest.Disk
        if let observed = attachment.disk {
            disk = observed
        } else {
            disk = try await Task {
                guard try attachment.usb.isAttached(alongside: otherUSB, in: instance) else {
                    throw cleanupRequired(id)
                }
                do {
                    return try await withGuest(in: instance) { guest in
                        try await guest.newDisk(after: otherDisks)
                    }
                } catch {
                    // The rootfs has not been passed to LinuxPod. Remove only
                    // our USB device and retain the unresolved guest generation.
                    try? await attachment.usb.change(.detach, alongside: otherUSB, in: instance)
                    throw error
                }
            }.value
            owned[id]?.disk = disk
        }
        try await Task {
            try await withGuest(in: instance) { guest in
                let attached = try attachment.usb.isAttached(alongside: otherUSB, in: instance)
                try await guest.verifyUnmounted(disk, containerID: id, canUnmount: attached)
                if attached {
                    try await attachment.usb.change(.detach, alongside: otherUSB, in: instance)
                }
                try await guest.confirmRemoval(of: disk, leaving: otherDisks)
                try VZUSBStorage.verifyDevices(otherUSB, in: instance)
            }
        }.value
        _ = instance.withMountRegistry { $0.removeValue(forKey: id) }
        owned.removeValue(forKey: id)
    }

    private static func withGuest<Value>(
        in instance: VZVirtualMachineInstance,
        _ operation: (VZUSBRootfsGuest) async throws -> Value
    ) async throws -> Value {
        guard instance.state == .running else {
            throw ContainerizationError(.invalidState, message: "The hotplug guest must be running to verify storage")
        }
        let agent = try await instance.dialAgent()
        do {
            let value = try await operation(VZUSBRootfsGuest(agent: agent))
            try await agent.close()
            return value
        } catch {
            try? await agent.close()
            throw error
        }
    }

    private static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.count <= LinuxPod.maxIDLength, id != ".", id != "..", !id.contains("/"), !id.utf8.contains(0) else {
            throw ContainerizationError(.invalidArgument, message: "container ID must be a single path component")
        }
    }

    private static func cleanupRequired(_ id: String, cause: (any Error)? = nil) -> ContainerizationError {
        ContainerizationError(
            .invalidState,
            message: "USB cleanup for \(id) is unverified. Stop the pod before further attachments.",
            cause: cause
        )
    }
}
#endif
