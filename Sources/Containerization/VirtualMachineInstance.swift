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

import ContainerizationError
import Foundation

/// The runtime state of the virtual machine instance.
public enum VirtualMachineInstanceState: Sendable {
    case starting
    case running
    case stopped
    case stopping
    case unknown
}

/// A live instance of a virtual machine.
public protocol VirtualMachineInstance: Sendable {
    associatedtype Agent: VirtualMachineAgent

    // The state of the virtual machine.
    var state: VirtualMachineInstanceState { get }

    var mounts: [String: [AttachedFilesystem]] { get }
    /// Dial the Agent. It's up the VirtualMachineInstance to determine
    /// what port the agent is listening on.
    func dialAgent() async throws -> Agent
    /// Dial a vsock port in the guest.
    func dial(_ port: UInt32) async throws -> FileHandle
    /// Listen on a host vsock port.
    func listen(_ port: UInt32) throws -> VsockListener
    /// Start the virtual machine.
    func start() async throws
    /// Stop the virtual machine.
    func stop() async throws
    /// Pause the virtual machine.
    func pause() async throws
    /// Resume the virtual machine.
    func resume() async throws
}

extension VirtualMachineInstance {
    func pause() async throws {
        throw ContainerizationError(.unsupported, message: "pause")
    }
    func resume() async throws {
        throw ContainerizationError(.unsupported, message: "resume")
    }
}
