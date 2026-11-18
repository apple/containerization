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
@preconcurrency import Virtualization

/// Attach local ext4 root filesystems to a running VZ-backed LinuxPod.
///
/// Append this extension to ``LinuxPod/Configuration/extensions`` before creating the pod.
/// Each container needs a separate disk image. The guest kernel must support xHCI PCI,
/// USB mass storage and SCSI disks. The extension manages the VM's USB controller and
/// guest SCSI disks exclusively. Additional live mounts may use the standard guest
/// filesystems or named pod volumes. Guest binds that could retain another rootfs
/// outside its container's lifetime are unsupported.
public struct VZUSBRootfsHotplug: VZInstanceExtension {
    public init() {}

    public func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        mountsByID: [String: [Mount]]
    ) throws {
        guard config.usbControllers.isEmpty,
            !config.storageDevices.contains(where: { $0 is VZUSBMassStorageDeviceConfiguration })
        else {
            throw ContainerizationError(.unsupported, message: "Rootfs hotplug needs exclusive access to the VM's USB controller")
        }
        // An unmanaged guest bind could hold another member's rootfs after
        // its normal unmount, so boot members must also avoid those binds.
        for mounts in mountsByID.values {
            for mount in mounts {
                if case .any = mount.runtimeOptions {
                    try VZUSBRootfsGuest.validateMount(mount)
                }
            }
        }
        config.usbControllers = [VZXHCIControllerConfiguration()]
    }

    public func didCreate(_ instance: VZVirtualMachineInstance) throws {
        guard instance.hotplugProvider == nil else {
            throw ContainerizationError(.exists, message: "The VM already has a hotplug provider")
        }
        try VZUSBStorage.verifyDevices([], in: instance)
        let reserved = try Set(instance.bootDiskImageURLs.map { try VZDiskImageID($0) })
        instance.hotplugProvider = VZUSBRootfsProvider(instance: instance, reserved: reserved)
    }
}
#endif
