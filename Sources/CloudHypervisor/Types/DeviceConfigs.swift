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

extension CloudHypervisor {
    // MARK: - ImageType

    /// On-disk format of a `DiskConfig`'s backing file. When omitted on the
    /// wire, cloud-hypervisor defaults to `Unknown` and rejects writes to
    /// the disk (logging "Attempting to write to sector 0 on a disk without
    /// specifying image_type"); always set this explicitly.
    ///
    /// Raw values match the Rust `block::ImageType` enum variants used in
    /// CH's JSON serialization (PascalCase) — these differ from the
    /// lowercase tokens accepted on the `--disk` CLI flag.
    public enum ImageType: String, Sendable, Codable, Equatable {
        case raw = "Raw"
        case qcow2 = "Qcow2"
        case fixedVhd = "FixedVhd"
        case vhdx = "Vhdx"
        case unknown = "Unknown"
    }

    // MARK: - DiskConfig

    /// Virtio-blk disk configuration.
    ///
    /// Maps to `DiskConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct DiskConfig: Sendable, Codable, Equatable {
        /// Path to the disk image file.
        public var path: String
        /// Open the disk in read-only mode.
        public var readonly: Bool?
        /// Use O_DIRECT for disk I/O.
        public var direct: Bool?
        /// Enable IOMMU for this device.
        public var iommu: Bool?
        /// Optional device identifier.
        public var id: String?
        /// PCI segment to attach the device to.
        public var pciSegment: UInt16?
        /// On-disk format of the backing file.
        public var imageType: ImageType?

        public init(
            path: String,
            readonly: Bool? = nil,
            direct: Bool? = nil,
            iommu: Bool? = nil,
            id: String? = nil,
            pciSegment: UInt16? = nil,
            imageType: ImageType? = nil
        ) {
            self.path = path
            self.readonly = readonly
            self.direct = direct
            self.iommu = iommu
            self.id = id
            self.pciSegment = pciSegment
            self.imageType = imageType
        }

        enum CodingKeys: String, CodingKey {
            case path
            case readonly
            case direct
            case iommu
            case id
            case pciSegment = "pci_segment"
            case imageType = "image_type"
        }
    }

    // MARK: - NetConfig

    /// Virtio-net network device configuration.
    ///
    /// Maps to `NetConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct NetConfig: Sendable, Codable, Equatable {
        /// TAP device name on the host.
        public var tap: String?
        /// IPv4 address for the device.
        public var ip: String?
        /// IPv4 subnet mask.
        public var mask: String?
        /// MAC address for the device.
        public var mac: String?
        /// Maximum transmission unit.
        public var mtu: Int?
        /// Number of virtio queues.
        public var numQueues: Int?
        /// Size of each virtio queue.
        public var queueSize: Int?
        /// Optional device identifier.
        public var id: String?

        public init(
            tap: String? = nil,
            ip: String? = nil,
            mask: String? = nil,
            mac: String? = nil,
            mtu: Int? = nil,
            numQueues: Int? = nil,
            queueSize: Int? = nil,
            id: String? = nil
        ) {
            self.tap = tap
            self.ip = ip
            self.mask = mask
            self.mac = mac
            self.mtu = mtu
            self.numQueues = numQueues
            self.queueSize = queueSize
            self.id = id
        }

        enum CodingKeys: String, CodingKey {
            case tap
            case ip
            case mask
            case mac
            case mtu
            case numQueues = "num_queues"
            case queueSize = "queue_size"
            case id
        }
    }

    // MARK: - FsConfig

    /// Virtio-fs filesystem device configuration.
    ///
    /// Maps to `FsConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct FsConfig: Sendable, Codable, Equatable {
        /// Filesystem tag used by the guest to mount.
        public var tag: String
        /// Path to the virtiofsd Unix socket.
        public var socket: String
        /// Number of virtio queues.
        public var numQueues: Int?
        /// Size of each virtio queue.
        public var queueSize: Int?
        /// Optional device identifier.
        public var id: String?
        /// PCI segment to attach the device to.
        public var pciSegment: UInt16?

        public init(
            tag: String,
            socket: String,
            numQueues: Int? = nil,
            queueSize: Int? = nil,
            id: String? = nil,
            pciSegment: UInt16? = nil
        ) {
            self.tag = tag
            self.socket = socket
            self.numQueues = numQueues
            self.queueSize = queueSize
            self.id = id
            self.pciSegment = pciSegment
        }

        enum CodingKeys: String, CodingKey {
            case tag
            case socket
            case numQueues = "num_queues"
            case queueSize = "queue_size"
            case id
            case pciSegment = "pci_segment"
        }
    }

    // MARK: - VsockConfig

    /// Virtio-vsock configuration.
    ///
    /// Maps to `VsockConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct VsockConfig: Sendable, Codable, Equatable {
        /// Context ID (CID) for the vsock device.
        public var cid: UInt32
        /// Path to the vsock Unix socket on the host.
        public var socket: String
        /// Enable IOMMU for this device.
        public var iommu: Bool?
        /// Optional device identifier.
        public var id: String?

        public init(
            cid: UInt32,
            socket: String,
            iommu: Bool? = nil,
            id: String? = nil
        ) {
            self.cid = cid
            self.socket = socket
            self.iommu = iommu
            self.id = id
        }

        enum CodingKeys: String, CodingKey {
            case cid
            case socket
            case iommu
            case id
        }
    }

    // MARK: - PciDeviceInfo

    /// PCI device identifier returned by Cloud Hypervisor after device add.
    ///
    /// Maps to `PciDeviceInfo` in the Cloud Hypervisor OpenAPI spec.
    public struct PciDeviceInfo: Sendable, Codable, Equatable {
        /// Device identifier string.
        public var id: String
        /// PCI Bus:Device.Function address (e.g. `"0000:00:03.0"`).
        public var bdf: String

        public init(id: String, bdf: String) {
            self.id = id
            self.bdf = bdf
        }

        enum CodingKeys: String, CodingKey {
            case id
            case bdf
        }
    }
}
