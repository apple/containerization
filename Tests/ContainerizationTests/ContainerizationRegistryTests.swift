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
import Testing

@testable import Containerization

/// Tests for ContainerRegistry DNS discovery functionality
@Suite(.serialized)
struct ContainerizationRegistryTests {
    
    // MARK: - Basic Registration Tests
    
    @Test func registerSingleContainer() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(
            name: "container1",
            ipAddress: "192.168.1.10",
            network: "default"
        )
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 1)
        #expect(containers[0].name == "container1")
        #expect(containers[0].ipAddress == "192.168.1.10")
        #expect(containers[0].network == "default")
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "container1")
    }
    
    @Test func registerMultipleContainersOnSameNetwork() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "net1")
        await ContainerRegistry.shared.register(name: "c2", ipAddress: "192.168.1.11", network: "net1")
        await ContainerRegistry.shared.register(name: "c3", ipAddress: "192.168.1.12", network: "net1")
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("net1")
        #expect(containers.count == 3)
        
        let names = Set(containers.map { $0.name })
        #expect(names.contains("c1"))
        #expect(names.contains("c2"))
        #expect(names.contains("c3"))
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
        await ContainerRegistry.shared.unregister(name: "c2")
        await ContainerRegistry.shared.unregister(name: "c3")
    }
    
    @Test func registerContainersOnDifferentNetworks() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "net1")
        await ContainerRegistry.shared.register(name: "c2", ipAddress: "172.17.0.2", network: "net2")
        await ContainerRegistry.shared.register(name: "c3", ipAddress: "10.0.0.5", network: "net3")
        
        let net1Containers = await ContainerRegistry.shared.getContainersOnNetwork("net1")
        let net2Containers = await ContainerRegistry.shared.getContainersOnNetwork("net2")
        let net3Containers = await ContainerRegistry.shared.getContainersOnNetwork("net3")
        
        #expect(net1Containers.count == 1)
        #expect(net2Containers.count == 1)
        #expect(net3Containers.count == 1)
        
        #expect(net1Containers[0].name == "c1")
        #expect(net2Containers[0].name == "c2")
        #expect(net3Containers[0].name == "c3")
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
        await ContainerRegistry.shared.unregister(name: "c2")
        await ContainerRegistry.shared.unregister(name: "c3")
    }
    
    // MARK: - Unregistration Tests
    
    @Test func unregisterContainer() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "default")
        
        var containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 1)
        
        await ContainerRegistry.shared.unregister(name: "c1")
        
        containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 0)
    }
    
    @Test func unregisterContainerFromMultipleNetworks() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        // Register same container on two different networks
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "net1")
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "172.17.0.2", network: "net2")
        
        // Verify it's registered on both
        var net1Count = await ContainerRegistry.shared.getContainersOnNetwork("net1").count
        var net2Count = await ContainerRegistry.shared.getContainersOnNetwork("net2").count
        #expect(net1Count == 1)
        #expect(net2Count == 1)
        
        // Unregister should remove from ALL networks
        await ContainerRegistry.shared.unregister(name: "c1")
        
        net1Count = await ContainerRegistry.shared.getContainersOnNetwork("net1").count
        net2Count = await ContainerRegistry.shared.getContainersOnNetwork("net2").count
        #expect(net1Count == 0)
        #expect(net2Count == 0)
    }
    
    @Test func unregisterOneContainerLeavesOthers() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "default")
        await ContainerRegistry.shared.register(name: "c2", ipAddress: "192.168.1.11", network: "default")
        await ContainerRegistry.shared.register(name: "c3", ipAddress: "192.168.1.12", network: "default")
        
        await ContainerRegistry.shared.unregister(name: "c2")
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 2)
        
        let names = Set(containers.map { $0.name })
        #expect(names.contains("c1"))
        #expect(!names.contains("c2"))
        #expect(names.contains("c3"))
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
        await ContainerRegistry.shared.unregister(name: "c3")
    }
    
    // MARK: - Persistence Tests
    
    @Test func registryPersistsToFile() async throws {
        // Clean registry before test
        let registryPath = "/tmp/container-registry.json"
        try? FileManager.default.removeItem(atPath: registryPath)
        
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "default")
        
        // Verify the registry file was created
        #expect(FileManager.default.fileExists(atPath: registryPath))
        
        // Verify it contains valid JSON
        let data = try Data(contentsOf: URL(fileURLWithPath: registryPath))
        let decoded = try JSONDecoder().decode([String: [String: ContainerRegistry.ContainerInfo]].self, from: data)
        
        #expect(decoded["default"] != nil)
        #expect(decoded["default"]?["c1"] != nil)
        #expect(decoded["default"]?["c1"]?.ipAddress == "192.168.1.10")
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
    }
    
    @Test func registryLoadsFromFile() async throws {
        // Clean registry before test
        let registryPath = "/tmp/container-registry.json"
        try? FileManager.default.removeItem(atPath: registryPath)
        
        // Manually create a registry file
        let testData: [String: [String: ContainerRegistry.ContainerInfo]] = [
            "default": [
                "c1": ContainerRegistry.ContainerInfo(name: "c1", ipAddress: "192.168.1.10", network: "default")
            ]
        ]
        let data = try JSONEncoder().encode(testData)
        try data.write(to: URL(fileURLWithPath: registryPath))
        
        // Query should load from file
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        
        #expect(containers.count == 1)
        #expect(containers[0].name == "c1")
        #expect(containers[0].ipAddress == "192.168.1.10")
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
    }
    
    // MARK: - Network Isolation Tests
    
    @Test func networkIsolation() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "net1")
        await ContainerRegistry.shared.register(name: "c2", ipAddress: "192.168.1.11", network: "net1")
        await ContainerRegistry.shared.register(name: "c3", ipAddress: "172.17.0.2", network: "net2")
        await ContainerRegistry.shared.register(name: "c4", ipAddress: "172.17.0.3", network: "net2")
        await ContainerRegistry.shared.register(name: "c5", ipAddress: "10.0.0.5", network: "net3")
        
        let net1Containers = await ContainerRegistry.shared.getContainersOnNetwork("net1")
        let net2Containers = await ContainerRegistry.shared.getContainersOnNetwork("net2")
        let net3Containers = await ContainerRegistry.shared.getContainersOnNetwork("net3")
        
        // Verify network isolation - each network only sees its own containers
        #expect(net1Containers.count == 2)
        #expect(net2Containers.count == 2)
        #expect(net3Containers.count == 1)
        
        let net1Names = Set(net1Containers.map { $0.name })
        #expect(net1Names.contains("c1"))
        #expect(net1Names.contains("c2"))
        #expect(!net1Names.contains("c3"))
        #expect(!net1Names.contains("c4"))
        #expect(!net1Names.contains("c5"))
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
        await ContainerRegistry.shared.unregister(name: "c2")
        await ContainerRegistry.shared.unregister(name: "c3")
        await ContainerRegistry.shared.unregister(name: "c4")
        await ContainerRegistry.shared.unregister(name: "c5")
    }
    
    // MARK: - Edge Cases
    
    @Test func registerDuplicateName() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "default")
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.11", network: "default")
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        
        // Last registration should overwrite
        #expect(containers.count == 1)
        #expect(containers[0].ipAddress == "192.168.1.11")
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
    }
    
    @Test func getContainersOnNonexistentNetwork() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("nonexistent")
        #expect(containers.count == 0)
    }
    
    @Test func unregisterNonexistentContainer() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        // Should not crash
        await ContainerRegistry.shared.unregister(name: "nonexistent")
        
        // Verify registry is still functional
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "default")
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 1)
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
    }
    
    @Test func emptyRegistry() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 0)
    }
    
    @Test func getAllContainers() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "192.168.1.10", network: "net1")
        await ContainerRegistry.shared.register(name: "c2", ipAddress: "172.17.0.2", network: "net2")
        await ContainerRegistry.shared.register(name: "c3", ipAddress: "10.0.0.5", network: "net3")
        
        let allContainers = await ContainerRegistry.shared.getAllContainers()
        #expect(allContainers.count == 3)
        
        let names = Set(allContainers.map { $0.name })
        #expect(names.contains("c1"))
        #expect(names.contains("c2"))
        #expect(names.contains("c3"))
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
        await ContainerRegistry.shared.unregister(name: "c2")
        await ContainerRegistry.shared.unregister(name: "c3")
    }
    
    // MARK: - Concurrent Access Tests
    
    @Test func concurrentRegistration() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await ContainerRegistry.shared.register(
                        name: "c\(i)",
                        ipAddress: "192.168.1.\(i)",
                        network: "default"
                    )
                }
            }
        }
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 10)
        
        // Clean up after test
        for i in 0..<10 {
            await ContainerRegistry.shared.unregister(name: "c\(i)")
        }
    }
    
    @Test func concurrentUnregistration() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        // First register 10 containers
        for i in 0..<10 {
            await ContainerRegistry.shared.register(
                name: "c\(i)",
                ipAddress: "192.168.1.\(i)",
                network: "default"
            )
        }
        
        // Then unregister them concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await ContainerRegistry.shared.unregister(name: "c\(i)")
                }
            }
        }
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 0)
    }
    
    @Test func concurrentMixedOperations() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await withTaskGroup(of: Void.self) { group in
            // Register 5 containers
            for i in 0..<5 {
                group.addTask {
                    await ContainerRegistry.shared.register(
                        name: "c\(i)",
                        ipAddress: "192.168.1.\(i)",
                        network: "default"
                    )
                }
            }
            
            // Query while registering
            for _ in 0..<5 {
                group.addTask {
                    _ = await ContainerRegistry.shared.getContainersOnNetwork("default")
                }
            }
        }
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 5)
        
        // Clean up after test
        for i in 0..<5 {
            await ContainerRegistry.shared.unregister(name: "c\(i)")
        }
    }
    
    // MARK: - Special Character Tests
    
    @Test func containerNamesWithSpecialCharacters() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(name: "my-container", ipAddress: "192.168.1.10", network: "default")
        await ContainerRegistry.shared.register(name: "my_container", ipAddress: "192.168.1.11", network: "default")
        await ContainerRegistry.shared.register(name: "my.container", ipAddress: "192.168.1.12", network: "default")
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 3)
        
        let names = Set(containers.map { $0.name })
        #expect(names.contains("my-container"))
        #expect(names.contains("my_container"))
        #expect(names.contains("my.container"))
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "my-container")
        await ContainerRegistry.shared.unregister(name: "my_container")
        await ContainerRegistry.shared.unregister(name: "my.container")
    }
    
    // MARK: - IPv6 Tests
    
    @Test func ipv6Addresses() async throws {
        // Clean registry before test
        try? FileManager.default.removeItem(atPath: "/tmp/container-registry.json")
        
        await ContainerRegistry.shared.register(name: "c1", ipAddress: "fe80::1", network: "default")
        await ContainerRegistry.shared.register(name: "c2", ipAddress: "2001:db8::1", network: "default")
        
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        #expect(containers.count == 2)
        
        let ips = Set(containers.map { $0.ipAddress })
        #expect(ips.contains("fe80::1"))
        #expect(ips.contains("2001:db8::1"))
        
        // Clean up after test
        await ContainerRegistry.shared.unregister(name: "c1")
        await ContainerRegistry.shared.unregister(name: "c2")
    }
}