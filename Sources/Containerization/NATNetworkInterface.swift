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

#if os(macOS)

import vmnet
import Virtualization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Synchronization

/// An interface that uses NAT to provide an IP address for a given
/// container/virtual machine.
@available(macOS 26, *)
public final class NATNetworkInterface: Interface, Sendable {
    public let ipv4Address: CIDRv4
    public let ipv4Gateway: IPv4Address?
    public let macAddress: MACAddress?

    @available(macOS 26, *)
    // `reference` isn't used concurrently.
    public nonisolated(unsafe) let reference: vmnet_network_ref!

    @available(macOS 26, *)
    public init(
        ipv4Address: CIDRv4,
        ipv4Gateway: IPv4Address?,
        reference: sending vmnet_network_ref,
        macAddress: MACAddress? = nil
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.reference = reference
    }

    @available(macOS, obsoleted: 26, message: "Use init(ipv4Address:ipv4Gateway:reference:macAddress:) instead")
    public init(
        ipv4Address: CIDRv4,
        ipv4Gateway: IPv4Address?,
        macAddress: MACAddress? = nil
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.reference = nil
    }
}

@available(macOS 26, *)
extension NATNetworkInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress.description) else {
                throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
            }
            config.macAddress = mac
        }

        config.attachment = VZVmnetNetworkDeviceAttachment(network: self.reference)
        return config
    }
}

#endif
