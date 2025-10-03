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

#if os(macOS)
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging

/// A virtualization.framework backed `VirtualMachineManager` implementation.
public struct VZVirtualMachineManager: VirtualMachineManager {
    private let kernel: Kernel
    private let bootlog: String?
    private let initialFilesystem: Mount
    private let logger: Logger?

    public init(
        kernel: Kernel,
        initialFilesystem: Mount,
        bootlog: String? = nil,
        logger: Logger? = nil
    ) {
        self.kernel = kernel
        self.bootlog = bootlog
        self.initialFilesystem = initialFilesystem
        self.logger = logger
    }

    public func create(container: Container) throws -> any VirtualMachineInstance {
        guard let c = container as? LinuxContainer else {
            throw ContainerizationError(
                .invalidArgument,
                message: "provided container is not a LinuxContainer"
            )
        }

        return try VZVirtualMachineInstance(
            logger: self.logger,
            with: { config in
                config.cpus = container.cpus
                config.memoryInBytes = container.memoryInBytes

                config.kernel = self.kernel
                config.initialFilesystem = self.initialFilesystem

                config.interfaces = container.interfaces
                if let bootlog {
                    config.bootlog = URL(filePath: bootlog)
                }
                config.rosetta = c.config.rosetta
                config.nestedVirtualization = c.config.virtualization

                config.mounts = [c.rootfs] + c.config.mounts
            })
    }
}
#endif
