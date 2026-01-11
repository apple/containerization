//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

/// Statistics for a container.
public struct ContainerStatistics: Sendable {
    public var id: String
    public var process: ProcessStatistics
    public var memory: MemoryStatistics
    public var cpu: CPUStatistics
    public var blockIO: BlockIOStatistics
    public var networks: [NetworkStatistics]

    public init(
        id: String,
        process: ProcessStatistics,
        memory: MemoryStatistics,
        cpu: CPUStatistics,
        blockIO: BlockIOStatistics,
        networks: [NetworkStatistics]
    ) {
        self.id = id
        self.process = process
        self.memory = memory
        self.cpu = cpu
        self.blockIO = blockIO
        self.networks = networks
    }

    /// Process statistics for a container.
    public struct ProcessStatistics: Sendable {
        public var current: UInt64
        public var limit: UInt64

        public init(current: UInt64, limit: UInt64) {
            self.current = current
            self.limit = limit
        }
    }

    /// Memory statistics for a container.
    public struct MemoryStatistics: Sendable {
        public var usageBytes: UInt64
        public var limitBytes: UInt64
        public var swapUsageBytes: UInt64
        public var swapLimitBytes: UInt64
        public var cacheBytes: UInt64
        public var kernelStackBytes: UInt64
        public var slabBytes: UInt64
        public var pageFaults: UInt64
        public var majorPageFaults: UInt64

        public init(
            usageBytes: UInt64,
            limitBytes: UInt64,
            swapUsageBytes: UInt64,
            swapLimitBytes: UInt64,
            cacheBytes: UInt64,
            kernelStackBytes: UInt64,
            slabBytes: UInt64,
            pageFaults: UInt64,
            majorPageFaults: UInt64
        ) {
            self.usageBytes = usageBytes
            self.limitBytes = limitBytes
            self.swapUsageBytes = swapUsageBytes
            self.swapLimitBytes = swapLimitBytes
            self.cacheBytes = cacheBytes
            self.kernelStackBytes = kernelStackBytes
            self.slabBytes = slabBytes
            self.pageFaults = pageFaults
            self.majorPageFaults = majorPageFaults
        }
    }

    /// CPU statistics for a container.
    public struct CPUStatistics: Sendable {
        public var usageUsec: UInt64
        public var userUsec: UInt64
        public var systemUsec: UInt64
        public var throttlingPeriods: UInt64
        public var throttledPeriods: UInt64
        public var throttledTimeUsec: UInt64

        public init(
            usageUsec: UInt64,
            userUsec: UInt64,
            systemUsec: UInt64,
            throttlingPeriods: UInt64,
            throttledPeriods: UInt64,
            throttledTimeUsec: UInt64
        ) {
            self.usageUsec = usageUsec
            self.userUsec = userUsec
            self.systemUsec = systemUsec
            self.throttlingPeriods = throttlingPeriods
            self.throttledPeriods = throttledPeriods
            self.throttledTimeUsec = throttledTimeUsec
        }
    }

    /// Block I/O statistics for a container.
    public struct BlockIOStatistics: Sendable {
        public var devices: [BlockIODevice]

        public init(devices: [BlockIODevice]) {
            self.devices = devices
        }
    }

    /// Block I/O statistics for a specific device.
    public struct BlockIODevice: Sendable {
        public var major: UInt64
        public var minor: UInt64
        public var readBytes: UInt64
        public var writeBytes: UInt64
        public var readOperations: UInt64
        public var writeOperations: UInt64

        public init(
            major: UInt64,
            minor: UInt64,
            readBytes: UInt64,
            writeBytes: UInt64,
            readOperations: UInt64,
            writeOperations: UInt64
        ) {
            self.major = major
            self.minor = minor
            self.readBytes = readBytes
            self.writeBytes = writeBytes
            self.readOperations = readOperations
            self.writeOperations = writeOperations
        }
    }

    /// Statistics for a network interface.
    public struct NetworkStatistics: Sendable {
        public var interface: String
        public var receivedPackets: UInt64
        public var transmittedPackets: UInt64
        public var receivedBytes: UInt64
        public var transmittedBytes: UInt64
        public var receivedErrors: UInt64
        public var transmittedErrors: UInt64

        public init(
            interface: String,
            receivedPackets: UInt64,
            transmittedPackets: UInt64,
            receivedBytes: UInt64,
            transmittedBytes: UInt64,
            receivedErrors: UInt64,
            transmittedErrors: UInt64
        ) {
            self.interface = interface
            self.receivedPackets = receivedPackets
            self.transmittedPackets = transmittedPackets
            self.receivedBytes = receivedBytes
            self.transmittedBytes = transmittedBytes
            self.receivedErrors = receivedErrors
            self.transmittedErrors = transmittedErrors
        }
    }
}
