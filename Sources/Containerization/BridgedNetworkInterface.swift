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
import Virtualization

/// A network interface that bridges the container onto a host physical interface.
/// The IP address is assigned by the upstream DHCP server; `ipv4Address` is always nil.
@available(macOS 26, *)
public final class BridgedNetworkInterface: Interface, Sendable {
    public let hostInterfaceName: String
    public let macAddress: MACAddress?
    public let ipv4Address: CIDRv4? = nil
    public let ipv4Gateway: IPv4Address? = nil
    public let mtu: UInt32 = 1500

    public init(hostInterfaceName: String, macAddress: MACAddress? = nil) {
        self.hostInterfaceName = hostInterfaceName
        self.macAddress = macAddress
    }
}

@available(macOS 26, *)
extension BridgedNetworkInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        guard
            let vzIface = VZBridgedNetworkInterface.networkInterfaces
                .first(where: { $0.identifier == hostInterfaceName })
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "no bridged interface named \(hostInterfaceName)")
        }
        let config = VZVirtioNetworkDeviceConfiguration()
        config.attachment = VZBridgedNetworkDeviceAttachment(interface: vzIface)
        if let mac = macAddress, let vzMac = VZMACAddress(string: mac.description) {
            config.macAddress = vzMac
        }
        return config
    }
}

#endif
