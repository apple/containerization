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

#if os(Linux)
import CloudHypervisor
import ContainerizationExtras

/// An `Interface` specialization that can produce a `CloudHypervisor.NetConfig`
/// describing how the cloud-hypervisor VMM should attach the device.
public protocol CHInterface {
    func chNetConfig() throws -> CloudHypervisor.NetConfig
}

/// A TAP-backed network interface for the cloud-hypervisor backend.
///
/// IP configuration on the guest side is delegated to `vminitd` (matching the
/// macOS path). `chNetConfig()` therefore leaves CH's `ip`/`mask` fields nil —
/// those would assign an address to the host end of the TAP, which we do not
/// use. Bringing up the TAP and any bridge/NAT plumbing is the caller's
/// responsibility.
public struct TAPInterface: CHInterface, Interface, Sendable {
    public let tapName: String
    public let ipv4Address: CIDRv4
    public let ipv4Gateway: IPv4Address?
    public let macAddress: MACAddress?
    public let mtu: UInt32

    public init(
        tapName: String,
        ipv4Address: CIDRv4,
        ipv4Gateway: IPv4Address? = nil,
        macAddress: MACAddress? = nil,
        mtu: UInt32 = 1500
    ) {
        self.tapName = tapName
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.mtu = mtu
    }

    public func chNetConfig() throws -> CloudHypervisor.NetConfig {
        CloudHypervisor.NetConfig(
            tap: tapName,
            ip: nil,
            mask: nil,
            mac: macAddress?.description,
            mtu: Int(mtu),
            numQueues: nil,
            queueSize: nil,
            id: nil
        )
    }
}
#endif
