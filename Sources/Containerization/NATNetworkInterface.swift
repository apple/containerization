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

#if os(macOS)

import vmnet
import Virtualization
import ContainerizationError
import Foundation
import Synchronization

/// An interface that uses NAT to provide an IP address for a given
/// container/virtual machine.
@available(macOS 26, *)
public final class NATNetworkInterface: Interface, Sendable {
    public let address: String
    public let gateway: String?
    public let macAddress: String?

    @available(macOS 26, *)
    // `reference` isn't used concurrently.
    public nonisolated(unsafe) let reference: vmnet_network_ref!

    @available(macOS 26, *)
    public init(
        address: String,
        gateway: String?,
        reference: sending vmnet_network_ref,
        macAddress: String? = nil
    ) {
        self.address = address
        self.gateway = gateway
        self.macAddress = macAddress
        self.reference = reference
    }

    @available(macOS, obsoleted: 26, message: "Use init(address:gateway:reference:macAddress:) instead")
    public init(
        address: String,
        gateway: String?,
        macAddress: String? = nil
    ) {
        self.address = address
        self.gateway = gateway
        self.macAddress = macAddress
        self.reference = nil
    }
}

@available(macOS 26, *)
extension NATNetworkInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress) else {
                throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
            }
            config.macAddress = mac
        }

        config.attachment = VZVmnetNetworkDeviceAttachment(network: self.reference)
        return config
    }
}

#endif
