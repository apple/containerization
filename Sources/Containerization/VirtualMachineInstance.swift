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

    /// Hotplug a block device, returning the attached filesystem info.
    /// Throws if the VMM does not support hotplug or not available
    /// - Parameter block: The mount configuration for the block device to hotplug
    /// - Parameter id: The metadata ID to associate with this mount (e.g. container ID)
    /// - Returns: AttachedFilesystem with the device path in the guest
    func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem

    /// Register mounts for a container after hotplug.
    /// This is used to add the rootfs and additional mounts to the VM's mount registry
    /// so they can be found when building the container's OCI spec.
    /// - Parameter id: The container ID
    /// - Parameter rootfs: The rootfs attachment from hotplug
    /// - Parameter additionalMounts: Additional mounts (like /proc, /sys) to register
    func registerMounts(id: String, rootfs: AttachedFilesystem, additionalMounts: [Mount]) throws

    /// Release a hotplug device.
    /// This should be called when a hotplugged container is stopped or fails to start.
    /// - Parameter id: The container ID whose hotplug should be released
    func releaseHotplug(id: String) async throws

    /// Hotplug virtiofs directories into the running VM.
    /// - Parameter mounts: The virtiofs mounts to add
    /// - Parameter id: The container ID that owns these mounts
    func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws

    /// Release virtiofs shares for a container.
    /// - Parameter id: The container ID whose virtiofs shares should be released
    func releaseVirtioFS(id: String) async throws
}

extension VirtualMachineInstance {
    public func pause() async throws {
        throw ContainerizationError(.unsupported, message: "pause")
    }
    public func resume() async throws {
        throw ContainerizationError(.unsupported, message: "resume")
    }
    public func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        throw ContainerizationError(.unsupported, message: "hotplug not supported")
    }
    public func registerMounts(id: String, rootfs: AttachedFilesystem, additionalMounts: [Mount]) throws {
        // no-op default
    }
    public func releaseHotplug(id: String) async throws {
        // no-op default
    }
    public func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        // no-op default
    }
    public func releaseVirtioFS(id: String) async throws {
        // no-op default
    }
}
