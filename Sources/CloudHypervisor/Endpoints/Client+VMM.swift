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
    /// Ping the Cloud Hypervisor VMM process and return its version information.
    ///
    /// Maps to `GET /api/v1/vmm.ping` in the Cloud Hypervisor REST API.
    public func vmmPing() async throws -> CloudHypervisor.VmmPingResponse {
        try await get("/api/v1/vmm.ping")
    }

    /// Request the Cloud Hypervisor VMM process to shut down gracefully.
    ///
    /// Maps to `PUT /api/v1/vmm.shutdown` in the Cloud Hypervisor REST API.
    public func vmmShutdown() async throws {
        try await put("/api/v1/vmm.shutdown")
    }

    /// Retrieve information about the Cloud Hypervisor VMM process.
    ///
    /// Maps to `GET /api/v1/vmm.info` in the Cloud Hypervisor REST API.
    public func vmmInfo() async throws -> CloudHypervisor.VmmInfo {
        try await get("/api/v1/vmm.info")
    }
}
