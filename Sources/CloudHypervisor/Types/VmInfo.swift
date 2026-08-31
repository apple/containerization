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

extension CloudHypervisor {
    // MARK: - VmState

    /// Lifecycle state of a Cloud Hypervisor VM.
    ///
    /// Maps to `VmState` in the Cloud Hypervisor OpenAPI spec.
    /// The raw values match CH's literal strings exactly (capitalized).
    public enum VmState: String, Sendable, Codable, Equatable {
        case Created
        case Running
        case Shutdown
        case Paused
        case BreakPoint
    }

    // MARK: - VmInfo

    /// Response body for `GET /vm.info`.
    ///
    /// Maps to `VmInfo` in the Cloud Hypervisor OpenAPI spec.
    ///
    /// Note: the `device_tree` map (`[String: VmInfoDeviceNode]`) from the
    /// upstream OpenAPI spec is omitted in this v1 implementation — no current
    /// endpoint consumers require it. Add when needed.
    public struct VmInfo: Sendable, Codable, Equatable {
        /// The boot configuration used for this VM.
        public var config: VmConfig
        /// Current lifecycle state.
        public var state: VmState
        /// Actual memory size in bytes as reported by the VMM, if available.
        public var memoryActualSize: UInt64?

        public init(config: VmConfig, state: VmState, memoryActualSize: UInt64? = nil) {
            self.config = config
            self.state = state
            self.memoryActualSize = memoryActualSize
        }

        enum CodingKeys: String, CodingKey {
            case config
            case state
            case memoryActualSize = "memory_actual_size"
        }
    }

    // MARK: - VmmPingResponse

    /// Response body for `GET /vmm.ping`.
    ///
    /// Maps to `VmmPingResponse` in the Cloud Hypervisor OpenAPI spec.
    public struct VmmPingResponse: Sendable, Codable, Equatable {
        /// Cloud Hypervisor version string (e.g. `"v40.0"`).
        public var version: String
        /// PID of the VMM process, if provided.
        public var pid: Int?
        /// List of compiled-in feature flags, if provided.
        public var features: [String]?
        /// Build-time version string, if provided.
        public var buildVersion: String?

        public init(version: String, pid: Int? = nil, features: [String]? = nil, buildVersion: String? = nil) {
            self.version = version
            self.pid = pid
            self.features = features
            self.buildVersion = buildVersion
        }

        enum CodingKeys: String, CodingKey {
            case version
            case pid
            case features
            case buildVersion = "build_version"
        }
    }

    // MARK: - VmmInfo

    /// Response body for `GET /vmm.info`.
    ///
    /// Maps to a subset of the `VmmInfo` schema in the Cloud Hypervisor OpenAPI
    /// spec.  Only the fields needed by v1 consumers are included (YAGNI).
    public struct VmmInfo: Sendable, Codable, Equatable {
        /// Cloud Hypervisor version string (e.g. `"v40.0"`).
        public var version: String
        /// PID of the VMM process, if provided.
        public var pid: Int?
        /// Build-time version string, if provided.
        public var buildVersion: String?
        /// The currently-running VM's boot configuration, if a VM exists.
        public var config: VmConfig?

        public init(version: String, pid: Int? = nil, buildVersion: String? = nil, config: VmConfig? = nil) {
            self.version = version
            self.pid = pid
            self.buildVersion = buildVersion
            self.config = config
        }

        enum CodingKeys: String, CodingKey {
            case version
            case pid
            case buildVersion = "build_version"
            case config
        }
    }
}
