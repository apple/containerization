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

import Foundation

extension CloudHypervisor.Client {
    /// Hotplug a virtio-blk disk device into a running VM.
    ///
    /// Maps to `PUT /api/v1/vm.add-disk` in the Cloud Hypervisor REST API.
    public func vmAddDisk(_ config: CloudHypervisor.DiskConfig) async throws -> CloudHypervisor.PciDeviceInfo {
        try await put("/api/v1/vm.add-disk", body: config)
    }

    /// Hotplug a virtio-fs filesystem device into a running VM.
    ///
    /// Maps to `PUT /api/v1/vm.add-fs` in the Cloud Hypervisor REST API.
    public func vmAddFs(_ config: CloudHypervisor.FsConfig) async throws -> CloudHypervisor.PciDeviceInfo {
        try await put("/api/v1/vm.add-fs", body: config)
    }

    /// Hotplug a virtio-net network device into a running VM.
    ///
    /// Maps to `PUT /api/v1/vm.add-net` in the Cloud Hypervisor REST API.
    public func vmAddNet(_ config: CloudHypervisor.NetConfig) async throws -> CloudHypervisor.PciDeviceInfo {
        try await put("/api/v1/vm.add-net", body: config)
    }

    /// Hotplug a virtio-vsock device into a running VM.
    ///
    /// Maps to `PUT /api/v1/vm.add-vsock` in the Cloud Hypervisor REST API.
    public func vmAddVsock(_ config: CloudHypervisor.VsockConfig) async throws -> CloudHypervisor.PciDeviceInfo {
        try await put("/api/v1/vm.add-vsock", body: config)
    }

    /// Remove a hotplugged device from a running VM by its identifier.
    ///
    /// Maps to `PUT /api/v1/vm.remove-device` in the Cloud Hypervisor REST API.
    public func vmRemoveDevice(id: String) async throws {
        struct Request: Encodable, Sendable { let id: String }
        try await put("/api/v1/vm.remove-device", body: Request(id: id))
    }
}
