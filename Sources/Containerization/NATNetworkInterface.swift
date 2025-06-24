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
import SendableProperty

/// An interface that uses NAT to provide an IP address for a given
/// container/virtual machine.
@available(macOS 26, *)
public final class NATNetworkInterface: Interface, Sendable {
    public var address: String {
        get { state.address }
        set { state.address = newValue }

    }

    public var gateway: String {
        get { state.gateway }
        set { state.gateway = newValue }
    }

    #if !CURRENT_SDK
    public var reference: vmnet_network_ref {
        state.reference
    }
    #endif

    public var macAddress: String? {
        get { state.macAddress }
        set { state.macAddress = newValue }
    }

    struct State {
        var address: String
        var gateway: String
        #if !CURRENT_SDK
        var reference: vmnet_network_ref
        #endif
        var macAddress: String?
    }

    @SendableProperty
    private var state: State
    #if !CURRENT_SDK
    public init(
        address: String,
        gateway: String,
        reference: sending vmnet_network_ref,
        macAddress: String? = nil
    ) {
        self.state = .init(
            address: address,
            gateway: gateway,
            reference: reference,
            macAddress: macAddress
        )
    }
    #else
    public init(
        address: String,
        gateway: String,
        macAddress: String? = nil
    ) {
        self.state = .init(
            address: address,
            gateway: gateway,
            macAddress: macAddress
        )
    }
    #endif
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

        #if !CURRENT_SDK
        config.attachment = VZVmnetNetworkDeviceAttachment(network: self.reference)
        #else
        config.attachment = VZNATNetworkDeviceAttachment()
        #endif
        return config
    }
}

#endif
