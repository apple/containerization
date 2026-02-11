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

#if os(macOS)
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import NIOCore

/// A virtualization.framework backed `VirtualMachineManager` implementation.
public struct VZVirtualMachineManager: VirtualMachineManager {
    private let kernel: Kernel
    private let initialFilesystem: Mount
    private let rosetta: Bool
    private let nestedVirtualization: Bool
    private let group: EventLoopGroup?
    private let logger: Logger?

    public init(
        kernel: Kernel,
        initialFilesystem: Mount,
        rosetta: Bool = false,
        nestedVirtualization: Bool = false,
        group: EventLoopGroup? = nil,
        logger: Logger? = nil
    ) {
        self.kernel = kernel
        self.initialFilesystem = initialFilesystem
        self.rosetta = rosetta
        self.nestedVirtualization = nestedVirtualization
        self.group = group
        self.logger = logger
    }

    public func create(config: some VMCreationConfig) throws -> any VirtualMachineInstance {
        let vmConfig = config.configuration

        // Use nested virtualization if requested in config or set as default in manager
        let useNestedVirtualization = vmConfig.nestedVirtualization || self.nestedVirtualization

        return try VZVirtualMachineInstance(
            group: self.group,
            logger: self.logger,
            with: { instanceConfig in
                instanceConfig.cpus = vmConfig.cpus
                instanceConfig.memoryInBytes = vmConfig.memoryInBytes

                instanceConfig.kernel = self.kernel
                instanceConfig.initialFilesystem = self.initialFilesystem

                if let bootLog = vmConfig.bootLog {
                    instanceConfig.bootLog = bootLog
                }

                instanceConfig.interfaces = vmConfig.interfaces
                instanceConfig.rosetta = self.rosetta
                instanceConfig.nestedVirtualization = useNestedVirtualization

                instanceConfig.mountsByID = vmConfig.mountsByID
            })
    }
}
#endif
