//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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
import Foundation

/// Protocol for VM creation configuration. Allows VMMs to extend with specific settings
/// while maintaining a common core configuration.
public protocol VMCreationConfig: Sendable {
    /// The common VM configuration that all VMMs must support.
    var configuration: VMConfiguration { get }
}

/// Standard VM creation configuration with only common settings.
public struct StandardVMConfig: VMCreationConfig {
    public var configuration: VMConfiguration

    public init(configuration: VMConfiguration) {
        self.configuration = configuration
    }
}

/// Configuration for creating a virtual machine instance.
public struct VMConfiguration: Sendable {
    /// The amount of CPUs to allocate.
    public var cpus: Int
    /// The memory in bytes to allocate.
    public var memoryInBytes: UInt64
    /// The network interfaces to attach.
    public var interfaces: [any Interface]
    /// Mounts organized by metadata ID (e.g. container ID).
    /// Each ID maps to an array of mounts for that workload.
    public var mountsByID: [String: [Mount]]
    /// Optional file path to store serial boot logs.
    public var bootlog: URL?
    /// Enable nested virtualization support. If the VirtualMachineManager
    /// does not support this feature, it MUST return an .unsupported ContainerizationError.
    public var nestedVirtualization: Bool

    public init(
        cpus: Int = 4,
        memoryInBytes: UInt64 = 1024 * 1024 * 1024,
        interfaces: [any Interface] = [],
        mountsByID: [String: [Mount]] = [:],
        bootlog: URL? = nil,
        nestedVirtualization: Bool = false
    ) {
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.interfaces = interfaces
        self.mountsByID = mountsByID
        self.bootlog = bootlog
        self.nestedVirtualization = nestedVirtualization
    }
}
