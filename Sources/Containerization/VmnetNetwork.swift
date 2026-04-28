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
import vmnet

/// A network backed by vmnet on macOS.
@available(macOS 26.0, *)
public struct VmnetNetwork: Network {
    private var allocator: Allocator
    // `reference` isn't used concurrently.
    nonisolated(unsafe) private let reference: vmnet_network_ref

    /// The IPv4 subnet of this network.
    public let subnet: CIDRv4

    /// The IPv4 gateway address of this network.
    public var ipv4Gateway: IPv4Address {
        subnet.gateway
    }

    struct Allocator: Sendable {
        private let addressAllocator: any AddressAllocator<UInt32>
        private let cidr: CIDRv4
        private var allocations: [String: UInt32]

        init(cidr: CIDRv4) throws {
            self.cidr = cidr
            self.allocations = .init()
            let size = Int(cidr.upper.value - cidr.lower.value - 3)
            self.addressAllocator = try UInt32.rotatingAllocator(
                lower: cidr.lower.value + 2,
                size: UInt32(size)
            )
        }

        mutating func allocate(_ id: String) throws -> CIDRv4 {
            if allocations[id] != nil {
                throw ContainerizationError(.exists, message: "allocation with id \(id) already exists")
            }
            let index = try addressAllocator.allocate()
            allocations[id] = index
            let ip = IPv4Address(index)
            return try CIDRv4(ip, prefix: cidr.prefix)
        }

        mutating func release(_ id: String) throws {
            if let index = self.allocations[id] {
                try addressAllocator.release(index)
                allocations.removeValue(forKey: id)
            }
        }
    }

    /// A network interface supporting the vmnet_network_ref.
    public struct Interface: Containerization.Interface, VZInterface, Sendable {
        public let ipv4Address: CIDRv4?
        public let ipv4Gateway: IPv4Address?
        public let macAddress: MACAddress?
        public let mtu: UInt32

        // `reference` isn't used concurrently.
        nonisolated(unsafe) private let reference: vmnet_network_ref

        public init(
            reference: vmnet_network_ref,
            ipv4Address: CIDRv4,
            ipv4Gateway: IPv4Address? = nil,
            macAddress: MACAddress? = nil,
            mtu: UInt32 = 1500
        ) {
            self.ipv4Address = ipv4Address
            self.ipv4Gateway = ipv4Gateway
            self.macAddress = macAddress
            self.mtu = mtu
            self.reference = reference
        }

        /// Returns the underlying `VZVirtioNetworkDeviceConfiguration`.
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

    /// Creates a new network.
    /// - Parameters:
    ///   - mode: The vmnet operating mode. Defaults to `.VMNET_SHARED_MODE`.
    ///   - subnet: The subnet to use for this network.
    public init(mode: vmnet.operating_modes_t = .VMNET_SHARED_MODE, subnet: CIDRv4? = nil) throws {
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let config = vmnet_network_configuration_create(mode, &status) else {
            throw ContainerizationError(.unsupported, message: "failed to create vmnet config with status \(status)")
        }

        vmnet_network_configuration_disable_dhcp(config)

        if let subnet {
            try Self.configureSubnet(config, subnet: subnet)
        }

        guard let ref = vmnet_network_create(config, &status), status == .VMNET_SUCCESS else {
            throw ContainerizationError(.unsupported, message: "failed to create vmnet network with status \(status)")
        }

        let cidr = try Self.getSubnet(ref)

        self.allocator = try .init(cidr: cidr)
        self.subnet = cidr
        self.reference = ref
    }

    /// Returns a new interface for use with a container.
    /// - Parameter id: The container ID.
    public mutating func createInterface(_ id: String) throws -> Containerization.Interface? {
        let ipv4Address = try allocator.allocate(id)
        return Self.Interface(
            reference: self.reference,
            ipv4Address: ipv4Address,
            ipv4Gateway: self.ipv4Gateway,
        )
    }

    /// Returns a new interface without a default gateway route.
    /// Use this for secondary interfaces where another interface already provides the default route.
    /// - Parameter id: The container ID.
    public mutating func createInterfaceWithoutGateway(_ id: String) throws -> Containerization.Interface? {
        let ipv4Address = try allocator.allocate(id)
        return Self.Interface(
            reference: self.reference,
            ipv4Address: ipv4Address,
        )
    }

    /// Returns a new interface for use with a container with a custom MTU.
    /// - Parameters:
    ///   - id: The container ID.
    ///   - mtu: The MTU for the interface.
    public mutating func createInterface(_ id: String, mtu: UInt32) throws -> Containerization.Interface? {
        let ipv4Address = try allocator.allocate(id)
        return Self.Interface(
            reference: self.reference,
            ipv4Address: ipv4Address,
            ipv4Gateway: self.ipv4Gateway,
            mtu: mtu
        )
    }

    /// Performs cleanup of an interface.
    /// - Parameter id: The container ID.
    public mutating func releaseInterface(_ id: String) throws {
        try allocator.release(id)
    }

    private static func getSubnet(_ ref: vmnet_network_ref) throws -> CIDRv4 {
        var subnet = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(ref, &subnet, &mask)

        let sa = UInt32(bigEndian: subnet.s_addr)
        let mv = UInt32(bigEndian: mask.s_addr)

        let lower = IPv4Address(sa & mv)
        let upper = IPv4Address(lower.value + ~mv)

        return try CIDRv4(lower: lower, upper: upper)
    }

    private static func configureSubnet(_ config: vmnet_network_configuration_ref, subnet: CIDRv4) throws {
        let gateway = subnet.gateway

        var ga = in_addr()
        inet_pton(AF_INET, gateway.description, &ga)

        let mask = IPv4Address(subnet.prefix.prefixMask32)
        var ma = in_addr()
        inet_pton(AF_INET, mask.description, &ma)

        guard vmnet_network_configuration_set_ipv4_subnet(config, &ga, &ma) == .VMNET_SUCCESS else {
            throw ContainerizationError(.internalError, message: "failed to set subnet \(subnet) for network")
        }
    }
}

#endif
