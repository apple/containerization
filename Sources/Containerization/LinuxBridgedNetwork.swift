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
import ContainerizationError
import ContainerizationExtras
import ContainerizationNetlink
import Crypto
import Foundation

/// A `Network` implementation backed by Linux TAP devices, optionally
/// enslaved to a pre-existing bridge. The bridge itself is **not** managed
/// by this type — callers own its creation, teardown, and any NAT/firewall
/// rules. This abstraction only handles per-VM TAP lifecycle and IPv4
/// address allocation within a configured subnet.
///
/// Mirrors the `VmnetNetwork` shape on macOS so the two backends are
/// interchangeable from a `LinuxContainer`/`Network` consumer's POV.
///
/// Requires `CAP_NET_ADMIN` for TAP creation and bridge enslavement.
public struct LinuxBridgedNetwork: Network {
    /// The IPv4 subnet from which container interfaces are allocated.
    public let subnet: CIDRv4
    /// The default-route gateway for containers attached to this network.
    public let ipv4Gateway: IPv4Address
    /// Optional bridge name to enslave each created TAP to.
    public let bridge: String?
    /// MTU applied to every TAP this network creates.
    public let mtu: UInt32

    private var allocator: Allocator
    private var taps: [String: TAPDevice]

    /// Per-id rotating IPv4 allocator. Mirrors `VmnetNetwork.Allocator`
    /// verbatim: lower bound = `subnet.lower + 2` (gateway = `lower + 1`,
    /// network = `lower`), size = `upper - lower - 3` (broadcast = `upper`,
    /// also reserved).
    struct Allocator: Sendable {
        private let addressAllocator: any AddressAllocator<UInt32>
        private let cidr: CIDRv4
        private var allocations: [String: UInt32]

        init(cidr: CIDRv4) throws {
            self.cidr = cidr
            self.allocations = [:]
            let span = cidr.upper.value - cidr.lower.value
            guard span >= 4 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "subnet \(cidr) has no usable host addresses (need at least 4)"
                )
            }
            let size = Int(span - 3)
            self.addressAllocator = try UInt32.rotatingAllocator(
                lower: cidr.lower.value + 2,
                size: UInt32(size)
            )
        }

        mutating func allocate(_ id: String) throws -> CIDRv4 {
            if allocations[id] != nil {
                throw ContainerizationError(
                    .exists,
                    message: "allocation with id \(id) already exists"
                )
            }
            let index = try addressAllocator.allocate()
            allocations[id] = index
            return try CIDRv4(IPv4Address(index), prefix: cidr.prefix)
        }

        mutating func release(_ id: String) throws {
            if let index = allocations[id] {
                try addressAllocator.release(index)
                allocations.removeValue(forKey: id)
            }
        }
    }

    /// Create a Linux bridged network.
    ///
    /// - Parameters:
    ///   - subnet: The IPv4 subnet to allocate container addresses from.
    ///   - gateway: Default-route gateway IPv4. If nil, defaults to
    ///     `subnet.gateway` (= `lower + 1`).
    ///   - bridge: Existing bridge name to enslave each TAP to, or nil for
    ///     standalone TAPs. Validated at init time via netlink.
    ///   - mtu: MTU applied to every created TAP (default 1500).
    public init(
        subnet: CIDRv4,
        gateway: IPv4Address? = nil,
        bridge: String? = nil,
        mtu: UInt32 = 1500
    ) throws {
        self.subnet = subnet
        self.ipv4Gateway = gateway ?? subnet.gateway
        self.bridge = bridge
        self.mtu = mtu
        self.allocator = try Allocator(cidr: subnet)
        self.taps = [:]

        if let bridge {
            // Validate via the public linkGet — empty result or netlink error
            // means the bridge does not exist or is unreachable.
            let session = try NetlinkSession(socket: DefaultNetlinkSocket())
            do {
                let links = try session.linkGet(interface: bridge)
                guard !links.isEmpty else {
                    throw ContainerizationError(
                        .notFound,
                        message: "bridge \(bridge) not found"
                    )
                }
            } catch let err as ContainerizationError {
                throw err
            } catch {
                throw ContainerizationError(
                    .notFound,
                    message: "bridge \(bridge) not found: \(error)"
                )
            }
        }
    }

    public mutating func createInterface(_ id: String) throws -> Interface? {
        let cidr = try allocator.allocate(id)
        let tapName = Self.derivedTAPName(forID: id)

        let device: TAPDevice
        do {
            device = try TAPDevice(
                name: tapName,
                bridge: bridge,
                mtu: mtu,
                macAddress: nil
            )
        } catch {
            // Roll back the allocator so the IP isn't leaked.
            try? allocator.release(id)
            throw error
        }
        taps[id] = device

        return TAPInterface(
            tapName: device.name,
            ipv4Address: cidr,
            ipv4Gateway: ipv4Gateway,
            macAddress: nil,
            mtu: mtu
        )
    }

    public mutating func releaseInterface(_ id: String) throws {
        if let device = taps.removeValue(forKey: id) {
            device.close()
        }
        try allocator.release(id)
    }

    /// Derive a deterministic, IFNAMSIZ-compliant TAP name from a container id.
    /// Format: `czt-<10 hex chars>` (14 chars total; IFNAMSIZ-1 = 15).
    static func derivedTAPName(forID id: String) -> String {
        let hash = SHA256.hash(data: Data(id.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "czt-" + String(hex.prefix(10))
    }
}
#endif
