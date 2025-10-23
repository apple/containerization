import Containerization

@main
struct TestRegistry {
    static func main() async {
        // Register a test container
        await ContainerRegistry.shared.register(
            name: "test-manual",
            ipAddress: "192.168.1.100",
            network: "default"
        )
        
        // Query it back
        let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
        print("Found \(containers.count) containers on default network")
        for container in containers {
            print("  - \(container.name): \(container.ipAddress)")
        }
    }
}
