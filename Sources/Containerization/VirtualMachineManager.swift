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

import Foundation

/// A protocol to implement for virtual machine isolated containers.
public protocol VirtualMachineManager: Sendable {
    /// Create a virtual machine.
    ///
    /// - Parameters:
    ///   - config: The configuration of the virtual machine.
    ///   - savedState: The directory a virtual machine's state was saved to, or `nil` to create a
    ///     virtual machine that boots normally. The returned instance is prepared to be restored
    ///     from it but is not restored yet; call ``VirtualMachineInstance/restore(from:)`` on it.
    ///     A manager that cannot restore MUST throw an `.unsupported` ContainerizationError for a
    ///     non-nil value.
    func create(config: some VMCreationConfig, from savedState: URL?) async throws -> any VirtualMachineInstance
}

extension VirtualMachineManager {
    /// Create a virtual machine that boots normally.
    ///
    /// Swift does not allow a default argument on a protocol requirement, so this stands in for
    /// `savedState: nil`.
    public func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        try await create(config: config, from: nil)
    }
}
