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

import ContainerizationOCI

/// Block I/O resource limits applied to the container cgroup.
public struct LinuxBlockIO: Sendable {
    /// The relative weight of the cgroup for block I/O. Valid range is 10 to 1000.
    public var weight: UInt16?
    /// The relative weight applied to tasks of the cgroup but not their descendant cgroups.
    public var leafWeight: UInt16?
    /// Per-device weight overrides.
    public var weightDevice: [LinuxWeightDevice]
    /// Per-device read rate limits in bytes per second.
    public var throttleReadBpsDevice: [LinuxThrottleDevice]
    /// Per-device write rate limits in bytes per second.
    public var throttleWriteBpsDevice: [LinuxThrottleDevice]
    /// Per-device read rate limits in IO operations per second.
    public var throttleReadIOPSDevice: [LinuxThrottleDevice]
    /// Per-device write rate limits in IO operations per second.
    public var throttleWriteIOPSDevice: [LinuxThrottleDevice]

    public init(
        weight: UInt16? = nil,
        leafWeight: UInt16? = nil,
        weightDevice: [LinuxWeightDevice] = [],
        throttleReadBpsDevice: [LinuxThrottleDevice] = [],
        throttleWriteBpsDevice: [LinuxThrottleDevice] = [],
        throttleReadIOPSDevice: [LinuxThrottleDevice] = [],
        throttleWriteIOPSDevice: [LinuxThrottleDevice] = []
    ) {
        self.weight = weight
        self.leafWeight = leafWeight
        self.weightDevice = weightDevice
        self.throttleReadBpsDevice = throttleReadBpsDevice
        self.throttleWriteBpsDevice = throttleWriteBpsDevice
        self.throttleReadIOPSDevice = throttleReadIOPSDevice
        self.throttleWriteIOPSDevice = throttleWriteIOPSDevice
    }

    /// Convert to OCI format for transport.
    public func toOCI() -> ContainerizationOCI.LinuxBlockIO {
        ContainerizationOCI.LinuxBlockIO(
            weight: self.weight,
            leafWeight: self.leafWeight,
            weightDevice: self.weightDevice.map { $0.toOCI() },
            throttleReadBpsDevice: self.throttleReadBpsDevice.map { $0.toOCI() },
            throttleWriteBpsDevice: self.throttleWriteBpsDevice.map { $0.toOCI() },
            throttleReadIOPSDevice: self.throttleReadIOPSDevice.map { $0.toOCI() },
            throttleWriteIOPSDevice: self.throttleWriteIOPSDevice.map { $0.toOCI() }
        )
    }
}

/// A per-device block I/O weight override.
public struct LinuxWeightDevice: Sendable {
    /// The major device number.
    public var major: Int64
    /// The minor device number.
    public var minor: Int64
    /// The relative weight applied to the device. Valid range is 10 to 1000.
    public var weight: UInt16?
    /// The relative weight applied to tasks of the cgroup but not their descendant cgroups.
    public var leafWeight: UInt16?

    public init(
        major: Int64,
        minor: Int64,
        weight: UInt16? = nil,
        leafWeight: UInt16? = nil
    ) {
        self.major = major
        self.minor = minor
        self.weight = weight
        self.leafWeight = leafWeight
    }

    /// Convert to OCI format for transport.
    public func toOCI() -> ContainerizationOCI.LinuxWeightDevice {
        ContainerizationOCI.LinuxWeightDevice(
            major: self.major,
            minor: self.minor,
            weight: self.weight,
            leafWeight: self.leafWeight
        )
    }
}

/// A per-device block I/O throughput limit.
public struct LinuxThrottleDevice: Sendable {
    /// The major device number.
    public var major: Int64
    /// The minor device number.
    public var minor: Int64
    /// The rate limit applied to the device.
    public var rate: UInt64

    public init(major: Int64, minor: Int64, rate: UInt64) {
        self.major = major
        self.minor = minor
        self.rate = rate
    }

    /// Convert to OCI format for transport.
    public func toOCI() -> ContainerizationOCI.LinuxThrottleDevice {
        ContainerizationOCI.LinuxThrottleDevice(
            major: self.major,
            minor: self.minor,
            rate: self.rate
        )
    }
}
