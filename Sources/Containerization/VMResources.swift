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

import ContainerizationOS

/// The size of the virtual machine that containers run in.
///
/// Container cgroup limits are set separately on the container's configuration.
public struct VMResources: Sendable {
    /// The number of vCPUs.
    public var cpus: Int
    /// The memory in bytes. The VMM backend rounds it up to its required alignment.
    public var memoryInBytes: UInt64

    public init(cpus: Int = 4, memoryInBytes: UInt64 = 1024.mib()) {
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
    }

    /// 4 vCPUs and 1024 MiB.
    public static let `default` = VMResources()

    /// Memory for the guest kernel and `vminitd` beyond a container's limit.
    ///
    /// Never applied by the library; callers that want headroom add it:
    ///
    ///     VMResources(cpus: 2, memoryInBytes: 512.mib() + VMResources.guestMemoryOverhead)
    public static let guestMemoryOverhead: UInt64 = 128.mib()
}
