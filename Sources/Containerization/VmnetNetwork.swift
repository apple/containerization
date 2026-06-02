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

    /// The IPv6 prefix of this network.
    public let prefixV6: CIDRv6?

    /// The IPv4 gateway address of this network.
    public var ipv4Gateway: IPv4Address {
        subnet.gateway
    }

    /// The IPv6 gateway address of this network, if a prefix exists.
    public var ipv6Gateway: IPv6Address? {
        prefixV6?.gateway
    }

    struct Allocator: Sendable {
        private let indexAllocatorV4: any AddressAllocator<UInt32>
        private let indexAllocatorV6: (any AddressAllocator<UInt32>)?
        private let cidrV4: CIDRv4
        private let cidrV6: CIDRv6?
        private var allocations: [String: (v4: UInt32, v6: UInt32?)]

        init(cidrV4: CIDRv4, cidrV6: CIDRv6?) throws {
            self.cidrV4 = cidrV4
            self.cidrV6 = cidrV6
            self.allocations = .init()
            let v4Size = Int(cidrV4.upper.value - cidrV4.lower.value - 3)
            self.indexAllocatorV4 = try UInt32.rotatingAllocator(
                lower: cidrV4.lower.value + 2,
                size: UInt32(v4Size)
            )
            if cidrV6 != nil {
                // Independent v6 allocator. The host portion is sourced from a
                // UInt32 index regardless of prefix length, and we never need
                // more v6 entries than v4 can serve.
                self.indexAllocatorV6 = try UInt32.rotatingAllocator(
                    lower: 2,
                    size: UInt32(v4Size)
                )
            } else {
                self.indexAllocatorV6 = nil
            }
        }

        mutating func allocate(_ id: String) throws -> (CIDRv4, CIDRv6?) {
            if allocations[id] != nil {
                throw ContainerizationError(.exists, message: "allocation with id \(id) already exists")
            }
            let v4Index = try indexAllocatorV4.allocate()
            let v4 = try CIDRv4(IPv4Address(v4Index), prefix: cidrV4.prefix)

            var v6Index: UInt32? = nil
            let v6: CIDRv6?
            if let indexAllocatorV6, let cidrV6 {
                do {
                    let idx = try indexAllocatorV6.allocate()
                    v6Index = idx
                    let v6Value = (cidrV6.address.value & cidrV6.prefix.prefixMask128) | UInt128(idx)
                    v6 = try CIDRv6(IPv6Address(v6Value), prefix: cidrV6.prefix)
                } catch {
                    // Roll back v4 so the pair stays atomic.
                    try? indexAllocatorV4.release(v4Index)
                    throw error
                }
            } else {
                v6 = nil
            }

            allocations[id] = (v4: v4Index, v6: v6Index)
            return (v4, v6)
        }

        mutating func release(_ id: String) throws {
            if let entry = self.allocations[id] {
                try indexAllocatorV4.release(entry.v4)
                if let v6Index = entry.v6 {
                    try indexAllocatorV6?.release(v6Index)
                }
                allocations.removeValue(forKey: id)
            }
        }
    }

    /// A network interface supporting the vmnet_network_ref.
    public struct Interface: Containerization.Interface, VZInterface, Sendable {
        public let ipv4Address: CIDRv4
        public let ipv4Gateway: IPv4Address?
        public let ipv6Address: CIDRv6?
        public let ipv6Gateway: IPv6Address?
        public let macAddress: MACAddress?
        public let mtu: UInt32

        // `reference` isn't used concurrently.
        nonisolated(unsafe) private let reference: vmnet_network_ref

        public init(
            reference: vmnet_network_ref,
            ipv4Address: CIDRv4,
            ipv4Gateway: IPv4Address? = nil,
            ipv6Address: CIDRv6? = nil,
            ipv6Gateway: IPv6Address? = nil,
            macAddress: MACAddress? = nil,
            mtu: UInt32 = 1500
        ) {
            self.ipv4Address = ipv4Address
            self.ipv4Gateway = ipv4Gateway
            self.ipv6Address = ipv6Address
            self.ipv6Gateway = ipv6Gateway
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
    ///   - subnetV4: The IPv4 subnet to use for this network.
    ///   - prefixV6: The IPv6 prefix to use for this network.
    public init(
        mode: vmnet.operating_modes_t = .VMNET_SHARED_MODE,
        subnet: CIDRv4? = nil,
        prefixV6: CIDRv6? = nil
    ) throws {
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let config = vmnet_network_configuration_create(mode, &status) else {
            throw ContainerizationError(.unsupported, message: "failed to create vmnet config with status \(status)")
        }

        vmnet_network_configuration_disable_dhcp(config)

        if let subnet {
            try Self.configureSubnetV4(config, subnetV4: subnet)
        }
        if let prefixV6 {
            try Self.configurePrefixV6(config, prefixV6: prefixV6)
        }

        guard let ref = vmnet_network_create(config, &status), status == .VMNET_SUCCESS else {
            throw ContainerizationError(.unsupported, message: "failed to create vmnet network with status \(status)")
        }

        let cidrV4 = try Self.getSubnetV4(ref)
        let cidrV6 = Self.getPrefixV6(ref)

        self.allocator = try .init(cidrV4: cidrV4, cidrV6: cidrV6)
        self.subnet = cidrV4
        self.prefixV6 = cidrV6
        self.reference = ref
    }

    /// Returns a new interface for use with a container. Allocates an IPv4
    /// address from the network's subnet, and — when the network has an IPv6
    /// prefix — an IPv6 address from that prefix. The two allocations are
    /// independent.
    /// - Parameter id: The container ID.
    public mutating func createInterface(_ id: String) throws -> Containerization.Interface? {
        let (v4, v6) = try allocator.allocate(id)
        return Self.Interface(
            reference: self.reference,
            ipv4Address: v4,
            ipv4Gateway: self.ipv4Gateway,
            ipv6Address: v6,
            ipv6Gateway: self.ipv6Gateway
        )
    }

    /// Returns a new interface for use with a container with a custom MTU.
    /// - Parameters:
    ///   - id: The container ID.
    ///   - mtu: The MTU for the interface.
    public mutating func createInterface(_ id: String, mtu: UInt32) throws -> Containerization.Interface? {
        let (v4, v6) = try allocator.allocate(id)
        return Self.Interface(
            reference: self.reference,
            ipv4Address: v4,
            ipv4Gateway: self.ipv4Gateway,
            ipv6Address: v6,
            ipv6Gateway: self.ipv6Gateway,
            mtu: mtu
        )
    }

    /// Returns a new interface without a default gateway route. Useful for
    /// secondary interfaces where another interface already provides the
    /// default route.
    /// - Parameter id: The container ID.
    public mutating func createInterfaceWithoutGateway(_ id: String) throws -> Containerization.Interface? {
        let (v4, v6) = try allocator.allocate(id)
        return Self.Interface(
            reference: self.reference,
            ipv4Address: v4,
            ipv6Address: v6
        )
    }

    /// Performs cleanup of an interface.
    /// - Parameter id: The container ID.
    public mutating func releaseInterface(_ id: String) throws {
        try allocator.release(id)
    }

    private static func getSubnetV4(_ ref: vmnet_network_ref) throws -> CIDRv4 {
        var subnet = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(ref, &subnet, &mask)

        let sa = UInt32(bigEndian: subnet.s_addr)
        let mv = UInt32(bigEndian: mask.s_addr)

        let lower = IPv4Address(sa & mv)
        let upper = IPv4Address(lower.value + ~mv)

        return try CIDRv4(lower: lower, upper: upper)
    }

    private static func configureSubnetV4(_ config: vmnet_network_configuration_ref, subnetV4: CIDRv4) throws {
        let gateway = subnetV4.gateway

        var ga = in_addr()
        inet_pton(AF_INET, gateway.description, &ga)

        let mask = IPv4Address(subnetV4.prefix.prefixMask32)
        var ma = in_addr()
        inet_pton(AF_INET, mask.description, &ma)

        guard vmnet_network_configuration_set_ipv4_subnet(config, &ga, &ma) == .VMNET_SUCCESS else {
            throw ContainerizationError(.internalError, message: "failed to set IPv4 subnet \(subnetV4) for network")
        }
    }

    private static func getPrefixV6(_ ref: vmnet_network_ref) -> CIDRv6? {
        var p = in6_addr()
        var len: UInt8 = 0
        vmnet_network_get_ipv6_prefix(ref, &p, &len)

        guard len > 0, let prefix = Prefix.ipv6(len) else {
            return nil
        }

        let bytes: [UInt8] = withUnsafeBytes(of: p) { Array($0) }
        guard let address = try? IPv6Address(bytes) else {
            return nil
        }
        return try? CIDRv6(address, prefix: prefix)
    }

    private static func configurePrefixV6(_ config: vmnet_network_configuration_ref, prefixV6: CIDRv6) throws {
        var p = in6_addr()
        inet_pton(AF_INET6, prefixV6.lower.description, &p)

        guard vmnet_network_configuration_set_ipv6_prefix(config, &p, prefixV6.prefix.length) == .VMNET_SUCCESS else {
            throw ContainerizationError(.internalError, message: "failed to set IPv6 prefix \(prefixV6) for network")
        }
    }
}

#endif
