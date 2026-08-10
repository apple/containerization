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
    /// Create a VM with the given configuration.
    ///
    /// Maps to `PUT /api/v1/vm.create` in the Cloud Hypervisor REST API.
    public func vmCreate(_ config: CloudHypervisor.VmConfig) async throws {
        try await put("/api/v1/vm.create", body: config)
    }

    /// Boot the VM (transition from Created → Running).
    ///
    /// Maps to `PUT /api/v1/vm.boot` in the Cloud Hypervisor REST API.
    public func vmBoot() async throws {
        try await put("/api/v1/vm.boot")
    }

    /// Shut down the VM.
    ///
    /// Maps to `PUT /api/v1/vm.shutdown` in the Cloud Hypervisor REST API.
    public func vmShutdown() async throws {
        try await put("/api/v1/vm.shutdown")
    }

    /// Retrieve runtime information about the VM.
    ///
    /// Maps to `GET /api/v1/vm.info` in the Cloud Hypervisor REST API.
    public func vmInfo() async throws -> CloudHypervisor.VmInfo {
        try await get("/api/v1/vm.info")
    }

    /// Pause the running VM.
    ///
    /// Maps to `PUT /api/v1/vm.pause` in the Cloud Hypervisor REST API.
    public func vmPause() async throws {
        try await put("/api/v1/vm.pause")
    }

    /// Resume a paused VM.
    ///
    /// Maps to `PUT /api/v1/vm.resume` in the Cloud Hypervisor REST API.
    public func vmResume() async throws {
        try await put("/api/v1/vm.resume")
    }
}
