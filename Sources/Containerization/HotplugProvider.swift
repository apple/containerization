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

/// A provider that manages hotplug operations for a virtual machine instance.
///
/// Conforming types implement the mechanics of hotplugging block devices and
/// virtiofs shares into a running VM.
public protocol HotplugProvider: Sendable {
    /// Hotplug a block device into the running VM.
    /// - Parameters:
    ///   - block: The mount configuration for the block device
    ///   - id: The container ID to associate with this device
    /// - Returns: The attached filesystem with the device path in the guest
    func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem

    /// Register mounts for a container in the VM's mount registry.
    /// - Parameters:
    ///   - id: The container ID
    ///   - rootfs: The rootfs attachment from hotplug
    ///   - additionalMounts: Additional mounts to register
    func registerMounts(id: String, rootfs: AttachedFilesystem, additionalMounts: [Mount]) throws

    /// Release a hotplug device.
    /// - Parameter id: The container ID who should be released
    func releaseHotplug(id: String) async throws

    /// Hotplug virtiofs directories into the running VM.
    /// - Parameters:
    ///   - mounts: The virtiofs mounts to add
    ///   - id: The container ID that owns these mounts
    func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws

    /// Release virtiofs shares for a container.
    /// - Parameter id: The container ID whose shares should be released
    func releaseVirtioFS(id: String) async throws

    /// Clean up resources held by the provider.
    func cleanup()
}

extension HotplugProvider {
    public func cleanup() {}
}
