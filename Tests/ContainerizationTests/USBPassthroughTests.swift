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

#if os(macOS) && canImport(AccessoryAccess)
import ContainerizationExtras
import Testing
import Virtualization

@testable import Containerization

// `AAUSBAccessory` needs a physical device, so these only cover controller setup.
struct USBPassthroughTests {
    @available(macOS 27, *)
    private func configure(_ config: inout VZVirtualMachineConfiguration, with ext: USBPassthrough) throws {
        try ext.configureVZ(&config, allocator: Character.blockDeviceTagAllocator(), storageDeviceCount: 0, mountsByID: [:])
    }

    @Test func addsXHCIController() throws {
        guard #available(macOS 27, *) else { return }
        var config = VZVirtualMachineConfiguration()
        try configure(&config, with: USBPassthrough())

        #expect(config.usbControllers.count == 1)
        let controller = try #require(config.usbControllers.first as? VZXHCIControllerConfiguration)
        #expect(controller.usbDevices.isEmpty)
    }

    @Test func reusesExistingXHCIController() throws {
        guard #available(macOS 27, *) else { return }
        var config = VZVirtualMachineConfiguration()
        let existing = VZXHCIControllerConfiguration()
        config.usbControllers = [existing]

        try configure(&config, with: USBPassthrough())

        #expect(config.usbControllers.count == 1)
        #expect(config.usbControllers.first === existing)
    }

    @Test func multipleExtensionsShareOneController() throws {
        guard #available(macOS 27, *) else { return }
        var config = VZVirtualMachineConfiguration()
        try configure(&config, with: USBPassthrough())
        try configure(&config, with: USBPassthrough())

        #expect(config.usbControllers.count == 1)
    }
}
#endif
