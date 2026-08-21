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
import Virtualization

/// A network interface that connects the container to an arbitrary FileHandle-backed
/// network service. The service on the other end of the handle provides the network:
/// it might be an entirely simulated network, a virtual network such as a VPN, or a
/// bridge onto a host physical network.
///
/// Supply `ipv4Address` and `ipv4Gateway` when the guest address is known up front and
/// should be configured statically. Leave them nil when the address is assigned out of
/// band, for instance by a DHCP server reachable through the file handle.
@available(macOS 26, *)
public final class FileHandleNetworkInterface: Interface, Sendable {
    public let fileHandle: FileHandle
    public let ipv4Address: CIDRv4?
    public let ipv4Gateway: IPv4Address?
    public let macAddress: MACAddress?

    public init(
        fileHandle: FileHandle,
        ipv4Address: CIDRv4? = nil,
        ipv4Gateway: IPv4Address? = nil,
        macAddress: MACAddress? = nil
    ) {
        self.fileHandle = fileHandle
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
    }
}

@available(macOS 26, *)
extension FileHandleNetworkInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        config.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress.description) else {
                throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
            }
            config.macAddress = mac
        }
        return config
    }
}

#endif
