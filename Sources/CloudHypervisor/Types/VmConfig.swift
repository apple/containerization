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
    // MARK: - VmConfig

    /// Top-level VM boot / create payload.
    ///
    /// Maps to `VmConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct VmConfig: Sendable, Codable, Equatable {
        public var cpus: CpusConfig
        public var memory: MemoryConfig
        public var payload: PayloadConfig
        public var disks: [DiskConfig]?
        public var net: [NetConfig]?
        public var fs: [FsConfig]?
        public var vsock: VsockConfig?
        public var console: ConsoleConfig
        public var serial: ConsoleConfig

        public init(
            cpus: CpusConfig,
            memory: MemoryConfig,
            payload: PayloadConfig,
            disks: [DiskConfig]? = nil,
            net: [NetConfig]? = nil,
            fs: [FsConfig]? = nil,
            vsock: VsockConfig? = nil,
            console: ConsoleConfig,
            serial: ConsoleConfig
        ) {
            self.cpus = cpus
            self.memory = memory
            self.payload = payload
            self.disks = disks
            self.net = net
            self.fs = fs
            self.vsock = vsock
            self.console = console
            self.serial = serial
        }

        enum CodingKeys: String, CodingKey {
            case cpus
            case memory
            case payload
            case disks
            case net
            case fs
            case vsock
            case console
            case serial
        }
    }

    // MARK: - CpusConfig

    /// Guest CPU feature toggles.
    ///
    /// Maps to `CpuFeatures` in the Cloud Hypervisor OpenAPI spec.
    public struct CpuFeatures: Sendable, Codable, Equatable {
        /// Enable AMX tile state for the guest (x86_64 only).
        public var amx: Bool?

        public init(amx: Bool? = nil) {
            self.amx = amx
        }
    }

    /// How Cloud Hypervisor groups vCPU threads for Linux core scheduling.
    ///
    /// Maps to `CoreSchedulingMode` in the Cloud Hypervisor OpenAPI spec.
    public enum CoreSchedulingMode: String, Codable, Sendable {
        /// All vCPU threads of the VM share one core scheduling cookie.
        case Vm
        /// Each vCPU thread has its own core scheduling cookie.
        case Vcpu
        /// No core scheduling.
        case Off
    }

    /// CPU configuration for a VM.
    ///
    /// Maps to `CpusConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct CpusConfig: Sendable, Codable, Equatable {
        /// Number of vCPUs to boot with.
        public var bootVcpus: Int
        /// Maximum number of vCPUs (for hotplug).
        public var maxVcpus: Int
        /// Guest CPU features. Nil leaves the Cloud Hypervisor defaults.
        public var features: CpuFeatures?
        /// Core scheduling mode. Nil means the Cloud Hypervisor default, `.Vm`.
        public var coreScheduling: CoreSchedulingMode?
        /// Expose VMX (Intel) or SVM (AMD) to the guest, so that it can run its own
        /// VMs. Nil means the Cloud Hypervisor default, true.
        public var nested: Bool?

        public init(
            bootVcpus: Int,
            maxVcpus: Int,
            features: CpuFeatures? = nil,
            coreScheduling: CoreSchedulingMode? = nil,
            nested: Bool? = nil
        ) {
            self.bootVcpus = bootVcpus
            self.maxVcpus = maxVcpus
            self.features = features
            self.coreScheduling = coreScheduling
            self.nested = nested
        }

        enum CodingKeys: String, CodingKey {
            case bootVcpus = "boot_vcpus"
            case maxVcpus = "max_vcpus"
            case features
            case coreScheduling = "core_scheduling"
            case nested
        }
    }

    // MARK: - MemoryConfig

    /// Memory configuration for a VM.
    ///
    /// Maps to `MemoryConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct MemoryConfig: Sendable, Codable, Equatable {
        /// RAM size in bytes.
        public var size: UInt64
        /// Hotplug memory size in bytes.
        public var hotplugSize: UInt64?
        /// Enable memory merging (KSM).
        public var mergeable: Bool?
        /// Use a shared memory mapping (`MAP_SHARED`). Required when any
        /// vhost-user device (e.g. virtio-fs / virtiofsd) is attached —
        /// CH otherwise rejects `vm.boot` with "Using vhost-user requires
        /// using shared memory or huge pages".
        public var shared: Bool?
        /// Back guest RAM with hugetlbfs pages of the host's default huge page size.
        public var hugepages: Bool?
        /// Populate all guest RAM when the VM boots (`MADV_POPULATE_WRITE`).
        public var prefault: Bool?

        public init(
            size: UInt64,
            hotplugSize: UInt64? = nil,
            mergeable: Bool? = nil,
            shared: Bool? = nil,
            hugepages: Bool? = nil,
            prefault: Bool? = nil
        ) {
            self.size = size
            self.hotplugSize = hotplugSize
            self.mergeable = mergeable
            self.shared = shared
            self.hugepages = hugepages
            self.prefault = prefault
        }

        enum CodingKeys: String, CodingKey {
            case size
            case hotplugSize = "hotplug_size"
            case mergeable
            case shared
            case hugepages
            case prefault
        }
    }

    // MARK: - PayloadConfig

    /// Kernel / initramfs / cmdline payload for a VM.
    ///
    /// Maps to `PayloadConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct PayloadConfig: Sendable, Codable, Equatable {
        /// Path to the uncompressed kernel image (vmlinux).
        public var kernel: String
        /// Optional initramfs path.
        public var initramfs: String?
        /// Optional kernel command line.
        public var cmdline: String?

        public init(kernel: String, initramfs: String? = nil, cmdline: String? = nil) {
            self.kernel = kernel
            self.initramfs = initramfs
            self.cmdline = cmdline
        }

        enum CodingKeys: String, CodingKey {
            case kernel
            case initramfs
            case cmdline
        }
    }

    // MARK: - ConsoleConfig

    /// Console / serial device configuration.
    ///
    /// Maps to `ConsoleConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct ConsoleConfig: Sendable, Codable, Equatable {
        /// Console I/O mode.
        ///
        /// CH's OpenAPI spec uses these capitalized strings literally.
        public enum Mode: String, Codable, Sendable {
            case Off
            case Pty
            case Tty
            case File
            case Socket
            case Null
        }

        public var mode: Mode
        /// Path to the output file when `mode == .File`.
        public var file: String?
        /// Path to the Unix socket when `mode == .Socket`.
        public var socket: String?

        public init(mode: Mode, file: String? = nil, socket: String? = nil) {
            self.mode = mode
            self.file = file
            self.socket = socket
        }

        enum CodingKeys: String, CodingKey {
            case mode
            case file
            case socket
        }
    }

}
