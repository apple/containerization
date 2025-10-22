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

import Foundation

/// Tracks running containers and their network information for DNS resolution
public actor ContainerRegistry {
    public static let shared = ContainerRegistry()

    /// Information about a registered container
    public struct ContainerInfo: Sendable {
        public let name: String
        public let ipAddress: String
        public let network: String

        public init(name: String, ipAddress: String, network: String) {
            self.name = name
            self.ipAddress = ipAddress
            self.network = network
        }
    }

    // Store containers by network: [networkName : [containerName: ContainerInfo]]
    private var containers: [String: [String: ContainerInfo]] = [:]

    private init() {}

    /// Register a new container
    public func register(name: String, ipAddress: String, network: String) {
        if containers[network] == nil {
            containers[network] = [:]
        }
        containers[network]?[name] = ContainerInfo(name: name, ipAddress: ipAddress, network: network)
    }

    // Unregister a container
    public func unregister(name: String) {
        for (network, _) in containers {
            containers[network]?.removeValue(forKey: name)
        }
    }

    /// Get all containers on a specific network
    public func getContainersOnNetwork(_ network: String) -> [ContainerInfo] {
        return Array(containers[network]?.values.map { $0 } ?? [])
    }

    /// Get all registered containers (for debugging)
    public func getAllContainers() -> [ContainerInfo] {
        return containers.values.flatMap { $0.values }
    }
}