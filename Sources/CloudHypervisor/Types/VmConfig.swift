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

    /// CPU configuration for a VM.
    ///
    /// Maps to `CpusConfig` in the Cloud Hypervisor OpenAPI spec.
    public struct CpusConfig: Sendable, Codable, Equatable {
        /// Number of vCPUs to boot with.
        public var bootVcpus: Int
        /// Maximum number of vCPUs (for hotplug).
        public var maxVcpus: Int

        public init(bootVcpus: Int, maxVcpus: Int) {
            self.bootVcpus = bootVcpus
            self.maxVcpus = maxVcpus
        }

        enum CodingKeys: String, CodingKey {
            case bootVcpus = "boot_vcpus"
            case maxVcpus = "max_vcpus"
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

        public init(size: UInt64, hotplugSize: UInt64? = nil, mergeable: Bool? = nil, shared: Bool? = nil) {
            self.size = size
            self.hotplugSize = hotplugSize
            self.mergeable = mergeable
            self.shared = shared
        }

        enum CodingKeys: String, CodingKey {
            case size
            case hotplugSize = "hotplug_size"
            case mergeable
            case shared
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
