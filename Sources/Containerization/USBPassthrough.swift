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

// AccessoryAccess and `VZUSBPassthroughDevice` need the macOS 27 SDK; older SDKs skip this file.
#if os(macOS) && canImport(AccessoryAccess)
import AccessoryAccess
import ContainerizationError
import ContainerizationExtras
import Foundation
@preconcurrency import Virtualization

/// Passes host USB devices through to the guest over an emulated XHCI controller.
///
/// Add to `VMConfiguration.extensions` or `LinuxPod.Configuration.extensions`.
/// The controller is always added, so `accessories` can be empty and devices
/// attached later with ``VZVirtualMachineInstance/attachUSBDevice(_:)``.
///
/// Accessories come from `AAUSBAccessoryManager`, which requires the
/// `com.apple.developer.accessory-access.usb` entitlement and an app in the Dock.
/// A helper can receive them over XPC via `AAUSBAccessory(xpcRepresentation:)`.
///
/// Requires a guest kernel with `CONFIG_USB_XHCI_PCI`. Devices appear under
/// `/dev/bus/usb` in the guest and in `vmexec` containers, but not in containers
/// using `ociRuntimePath`, which get a tmpfs `/dev`.
@available(macOS 27, *)
public struct USBPassthrough: VZInstanceExtension {
    /// Accessories to capture at VM start.
    public var accessories: [AAUSBAccessory]

    public init(accessories: [AAUSBAccessory] = []) {
        self.accessories = accessories
    }

    public func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        mountsByID: [String: [Mount]]
    ) throws {
        let devices = accessories.map { VZUSBPassthroughDeviceConfiguration(device: $0) }
        if let controller = config.usbControllers.first(where: { $0 is VZXHCIControllerConfiguration }) {
            controller.usbDevices.append(contentsOf: devices)
            return
        }
        let controller = VZXHCIControllerConfiguration()
        controller.usbDevices = devices
        config.usbControllers.append(controller)
    }
}

@available(macOS 27, *)
extension VZVirtualMachineInstance {
    /// Captures `accessory` and attaches it to the running VM, which must use ``USBPassthrough``.
    /// - Returns: The device UUID, for ``detachUSBDevice(_:)``.
    public func attachUSBDevice(_ accessory: AAUSBAccessory) async throws -> UUID {
        try await withInstanceLock {
            guard self.state == .running else {
                throw ContainerizationError(.invalidState, message: "vm is not running")
            }
            return try await self.vzVirtualMachine.attachUSB(queue: self.vmQueue, accessory: accessory)
        }
    }

    /// Detaches a device attached at boot or with ``attachUSBDevice(_:)``.
    public func detachUSBDevice(_ uuid: UUID) async throws {
        try await withInstanceLock {
            try await self.vzVirtualMachine.detachUSB(queue: self.vmQueue, uuid: uuid)
        }
    }
}

extension VZVirtualMachine {
    @available(macOS 27, *)
    func attachUSB(queue: DispatchQueue, accessory: AAUSBAccessory) async throws -> UUID {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UUID, Error>) in
            queue.sync {
                guard let controller = self.usbControllers.first else {
                    cont.resume(
                        throwing: ContainerizationError(
                            .invalidState,
                            message: "vm has no USB controller; add USBPassthrough to the VM extensions"
                        )
                    )
                    return
                }
                let device: VZUSBPassthroughDevice
                do {
                    device = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory))
                } catch {
                    cont.resume(
                        throwing: ContainerizationError(.internalError, message: "failed to capture USB accessory", cause: error)
                    )
                    return
                }
                let uuid = device.uuid
                controller.attach(device: device) { error in
                    if let error {
                        cont.resume(
                            throwing: ContainerizationError(.internalError, message: "failed to attach USB device", cause: error)
                        )
                        return
                    }
                    cont.resume(returning: uuid)
                }
            }
        }
    }

    func detachUSB(queue: DispatchQueue, uuid: UUID) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                for controller in self.usbControllers {
                    guard let device = controller.usbDevices.first(where: { $0.uuid == uuid }) else {
                        continue
                    }
                    controller.detach(device: device) { error in
                        if let error {
                            cont.resume(
                                throwing: ContainerizationError(.internalError, message: "failed to detach USB device", cause: error)
                            )
                            return
                        }
                        cont.resume()
                    }
                    return
                }
                cont.resume(throwing: ContainerizationError(.notFound, message: "no USB device \(uuid) attached"))
            }
        }
    }
}
#endif
