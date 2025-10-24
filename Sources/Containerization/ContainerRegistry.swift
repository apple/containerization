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
    
    private let registryPath = "/tmp/container-registry.json"
    
    /// Information about a registered container
    public struct ContainerInfo: Sendable, Codable {
        public let name: String
        public let ipAddress: String
        public let network: String
        
        public init(name: String, ipAddress: String, network: String) {
            self.name = name
            self.ipAddress = ipAddress
            self.network = network
        }
    }
    
    private init() {}
    
    // Load registry from disk
    private func load() throws -> [String: [String: ContainerInfo]] {
        guard FileManager.default.fileExists(atPath: registryPath) else {
            return [:]
        }
        
        let data = try Data(contentsOf: URL(fileURLWithPath: registryPath))
        return try JSONDecoder().decode([String: [String: ContainerInfo]].self, from: data)
    }
    
    // Save registry to disk
    private func save(_ containers: [String: [String: ContainerInfo]]) throws {
        let data = try JSONEncoder().encode(containers)
        try data.write(to: URL(fileURLWithPath: registryPath), options: .atomic)
    }
    
    /// Register a new container
    public func register(name: String, ipAddress: String, network: String) {
        do {
            var containers = try load()
            
            if containers[network] == nil {
                containers[network] = [:]
            }
            containers[network]?[name] = ContainerInfo(name: name, ipAddress: ipAddress, network: network)
            
            try save(containers)
        } catch {
            // Log error but don't crash - registration failures shouldn't break container creation
            print("Warning: Failed to register container \(name) in registry: \(error)")
        }
    }
    
    /// Unregister a container
    public func unregister(name: String) {
        do {
            var containers = try load()
            
            for (network, _) in containers {
                containers[network]?.removeValue(forKey: name)
            }
            
            try save(containers)
        } catch {
            // Log error but don't crash - unregistration failures shouldn't break container cleanup
            print("Warning: Failed to unregister container \(name) from registry: \(error)")
        }
    }
    
    /// Get all containers on a specific network
    public func getContainersOnNetwork(_ network: String) -> [ContainerInfo] {
        do {
            let containers = try load()
            return Array(containers[network]?.values.map { $0 } ?? [])
        } catch {
            print("Warning: Failed to load registry when querying network \(network): \(error)")
            return []
        }
    }
    
    /// Get all registered containers (for debugging)
    public func getAllContainers() -> [ContainerInfo] {
        do {
            let containers = try load()
            return containers.values.flatMap { $0.values }
        } catch {
            print("Warning: Failed to load registry when getting all containers: \(error)")
            return []
        }
    }
}