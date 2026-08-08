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
import Logging
import Synchronization
@preconcurrency import Virtualization

/// Attaches block devices to a running virtual machine.
///
/// Virtualization's storage devices are fixed once a machine boots, but its USB
/// controller takes devices while it runs, and mass storage is one of the
/// devices it takes. A block device attached this way appears to the guest as a
/// SCSI disk, so it is named from a separate run of letters to the virtio-blk
/// devices the machine booted with.
/// https://developer.apple.com/documentation/virtualization/vzusbcontroller
@available(macOS 15.0, *)
final class VZHotplugProvider: HotplugProvider, @unchecked Sendable {
    /// A disk attached to the running machine, kept so it can be detached.
    ///
    /// The device is a Virtualization object, which is safe to touch on the
    /// machine's own queue and nowhere else. Every use of it here is inside a
    /// block dispatched to that queue.
    private struct HotplugRecord: @unchecked Sendable {
        let device: VZUSBMassStorageDevice
        let letter: Character
    }

    private let vm: VZVirtualMachine
    private let queue: DispatchQueue
    /// Names for the disks attached while the machine runs, which the guest
    /// numbers apart from the ones it booted with.
    private let allocator: any AddressAllocator<Character>
    private let _storage: Mutex<MachineAttachments>
    private let _records: Mutex<[String: [HotplugRecord]]>
    private let logger: Logger?

    init(
        vm: VZVirtualMachine,
        queue: DispatchQueue,
        initialStorage: MachineAttachments,
        logger: Logger?
    ) {
        self.vm = vm
        self.queue = queue
        self.allocator = Character.blockDeviceTagAllocator()
        self._storage = Mutex(initialStorage)
        self._records = Mutex([:])
        self.logger = logger
    }

    var storage: MachineAttachments {
        _storage.withLock { $0 }
    }

    func withStorage<T: Sendable>(
        _ body: (inout sending MachineAttachments) throws -> sending T
    ) rethrows -> T {
        try _storage.withLock(body)
    }

    // MARK: - HotplugProvider conformance

    func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        guard block.isBlock else {
            throw ContainerizationError(
                .invalidArgument,
                message: "only a block device can be attached to a running machine"
            )
        }
        // The controller and the device are Virtualization objects, touched
        // only inside a block dispatched to the machine's own queue.
        guard let first = vm.usbControllers.first else {
            throw ContainerizationError(
                .unsupported,
                message: "the machine has no USB controller to attach to"
            )
        }
        nonisolated(unsafe) let controller = first

        let letter = try allocator.allocate()
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(filePath: block.source),
                readOnly: block.options.contains("ro")
            )
            nonisolated(unsafe) let device = VZUSBMassStorageDevice(
                configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment)
            )

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    controller.attach(device: device) { error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        continuation.resume()
                    }
                }
            }

            _records.withLock {
                $0[id, default: []].append(HotplugRecord(device: device, letter: letter))
            }

            return AttachedFilesystem(
                type: block.type,
                source: "/dev/sd\(letter)",
                destination: block.destination,
                options: block.options
            )
        } catch {
            try? allocator.release(letter)
            throw error
        }
    }

    func registerMounts(id: String, rootfs: AttachedFilesystem, writableLayer: AttachedFilesystem?, additionalMounts: [Mount]) throws {
        var mounts: [AttachedFilesystem] = []
        for mount in additionalMounts {
            mounts.append(try AttachedFilesystem(mount: mount, allocator: allocator))
        }
        let container = ContainerAttachments(rootfs: rootfs, writableLayer: writableLayer, mounts: mounts)
        _storage.withLock {
            $0.containers[id] = container
        }
    }

    func releaseHotplug(id: String) async throws {
        let popped: [HotplugRecord] = _records.withLock { records in
            defer { records.removeValue(forKey: id) }
            return records[id] ?? []
        }
        guard let first = vm.usbControllers.first else {
            return
        }
        nonisolated(unsafe) let controller = first

        for record in popped {
            nonisolated(unsafe) let device = record.device
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    queue.async {
                        controller.detach(device: device) { error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            continuation.resume()
                        }
                    }
                }
            } catch {
                logger?.error(
                    "failed to detach a disk from the running machine",
                    metadata: ["id": "\(id)", "error": "\(error)"]
                )
            }
            try? allocator.release(record.letter)
        }

        _ = _storage.withLock { $0.containers.removeValue(forKey: id) }
    }

    /// Virtualization shares directories through devices fixed at boot, so a
    /// share cannot be added to a machine that is already running.
    func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        guard !mounts.isEmpty else { return }
        throw ContainerizationError(
            .unsupported,
            message: "a directory share cannot be added to a running machine"
        )
    }

    func releaseVirtioFS(id: String) async throws {}
}

#endif
