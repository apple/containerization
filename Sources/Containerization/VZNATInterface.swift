//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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
import Virtualization

/// Legacy NAT network interface backed by Virtualization.framework.
public struct VZNATInterface: Interface {
    public var address: String
    public var gateway: String
    public var macAddress: String?

    public init(address: String, gateway: String, macAddress: String? = nil) {
        self.address = address
        self.gateway = gateway
        self.macAddress = macAddress
    }
}

extension VZNATInterface: VZInterface {
    /// Turns the provided data on the interface into a valid
    /// Virtualization.framework `VZVirtioNetworkDeviceConfiguration`.
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "invalid mac address \(macAddress)"
                )
            }
            config.macAddress = mac
        }
        config.attachment = VZNATNetworkDeviceAttachment()
        return config
    }
}

#endif
