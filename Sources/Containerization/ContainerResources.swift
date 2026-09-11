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

/// The cgroup limits applied to a container running inside a sandbox.
///
/// These are separate from the size of the sandbox itself. A container may be
/// limited to less than the virtual machine it runs in, or oversubscribed
/// beyond it.
public struct ContainerResources: Sendable {
    /// The CPU limit, expressed as whole cores.
    ///
    /// Applied to the OCI runtime spec as a cgroup quota/period pair with a
    /// 100ms period, so a value of 2 becomes `cpu.max` of `200000 100000`.
    public var cpus: Int
    /// The memory limit in bytes.
    public var memoryInBytes: UInt64

    public init(cpus: Int = 4, memoryInBytes: UInt64 = 1024.mib()) {
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
    }

    /// Additional memory a sandbox needs beyond its container's limit to run the
    /// guest kernel and `vminitd`.
    ///
    /// The library never applies this for you — sizing the sandbox is the
    /// caller's decision. It exists so consumers that do want memory headroom
    /// agree on how much rather than each inventing a number:
    ///
    ///     config.resources = ContainerResources(cpus: 2, memoryInBytes: 512.mib())
    ///     config.cpus = 2
    ///     config.memoryInBytes = 512.mib() + ContainerResources.guestMemoryOverhead
    ///
    /// This is the memory headroom the library itself added implicitly before
    /// sandbox and container sizing were separated. There is no CPU equivalent:
    /// the guest kernel and `vminitd` are served fine by the container's own
    /// vCPUs, so a sandbox needs no extra core.
    public static let guestMemoryOverhead: UInt64 = 128.mib()
}
