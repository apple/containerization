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
/// `fileHandle` must wrap a *connected* `AF_UNIX` datagram socket carrying one Ethernet
/// frame per datagram. On platforms without automatic binding for unix datagram sockets,
/// including macOS, the socket also has to be bound to a local path of its own, or the
/// service has no address to send frames back to. Tuning `SO_SNDBUF` / `SO_RCVBUF` only
/// becomes relevant when raising the attachment MTU above its 1500-byte default.
///
/// Supply `ipv4Address` and `ipv4Gateway` when the guest address is known up front and
/// should be configured statically. They may be left nil only when something inside the
/// guest configures the interface instead: host-side setup for an address-less interface
/// brings the link up without assigning an address, and `vminitd` does not run a DHCP
/// client, so a guest that needs one has to supply it.
///
/// `mtu` configures the guest link. It is independent of the host-side attachment MTU,
/// which stays at the framework default because `VZFileHandleNetworkDeviceAttachment`
/// rejects values below 1500.
public final class FileHandleNetworkInterface: Interface, Sendable {
    public let fileHandle: FileHandle
    public let ipv4Address: CIDRv4?
    public let ipv4Gateway: IPv4Address?
    public let macAddress: MACAddress?
    public let mtu: UInt32

    public init(
        fileHandle: FileHandle,
        ipv4Address: CIDRv4? = nil,
        ipv4Gateway: IPv4Address? = nil,
        macAddress: MACAddress? = nil,
        mtu: UInt32 = 1500
    ) {
        self.fileHandle = fileHandle
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.mtu = mtu
    }
}

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
