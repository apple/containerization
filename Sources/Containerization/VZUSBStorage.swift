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
import Foundation
@preconcurrency import Virtualization

// Access the VZ device only on its VM's queue. Its UUID is safe to compare elsewhere.
struct VZUSBStorage: @unchecked Sendable {
    private let device: VZUSBMassStorageDevice
    let id: UUID

    init(_ block: Mount, options: [String], in instance: VZVirtualMachineInstance) throws {
        (device, id) = try instance.vmQueue.sync {
            let attachment = try VZDiskImageStorageDeviceAttachment.mountToVZAttachment(mount: block, options: options)
            let device = VZUSBMassStorageDevice(configuration: .init(attachment: attachment))
            return (device, device.uuid)
        }
    }

    static func verifyDevices(_ expected: Set<UUID>, in instance: VZVirtualMachineInstance) throws {
        try verify(expected, actual: deviceIDs(in: instance))
    }

    func isAttached(alongside owned: Set<UUID>, in instance: VZVirtualMachineInstance) throws -> Bool {
        let current = try Self.deviceIDs(in: instance)
        try Self.verify(owned, actual: current.subtracting([id]))
        return current.contains(id)
    }

    enum Operation {
        case attach
        case detach
    }

    func change(_ operation: Operation, alongside owned: Set<UUID>, in instance: VZVirtualMachineInstance) async throws {
        let includingDevice = owned.union([id])
        let before = operation == .attach ? owned : includingDevice
        let after = operation == .attach ? includingDevice : owned

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            instance.vmQueue.async {
                do {
                    let controller = try Self.controller(in: instance)
                    try Self.verify(before, actual: Set(controller.usbDevices.map(\.uuid)))
                    let completed: (Error?) -> Void = { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(with: Result { try Self.verify(after, actual: Set(controller.usbDevices.map(\.uuid))) })
                        }
                    }
                    switch operation {
                    case .attach:
                        controller.attach(device: self.device, completionHandler: completed)
                    case .detach:
                        controller.detach(device: self.device, completionHandler: completed)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func deviceIDs(in instance: VZVirtualMachineInstance) throws -> Set<UUID> {
        try instance.vmQueue.sync {
            try Set(controller(in: instance).usbDevices.map(\.uuid))
        }
    }

    private static func controller(in instance: VZVirtualMachineInstance) throws -> VZXHCIController {
        let controllers = instance.vzVirtualMachine.usbControllers
        guard controllers.count == 1, let controller = controllers.first as? VZXHCIController else {
            throw ContainerizationError(.unsupported, message: "Rootfs hotplug requires one exclusively managed xHCI controller")
        }
        return controller
    }

    private static func verify(_ expected: Set<UUID>, actual: Set<UUID>) throws {
        guard actual == expected else {
            throw ContainerizationError(.invalidState, message: "The VM's USB devices differ from the provider's owned devices")
        }
    }
}

/// Identify a backing file through both symlinks and hard links.
struct VZDiskImageID: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let device = attributes[.systemNumber] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber
        else {
            throw ContainerizationError(.invalidArgument, message: "expected a regular local disk image at \(url.path)")
        }
        self.device = device.uint64Value
        self.inode = inode.uint64Value
    }
}
#endif
