import Containerization

@MainActor
func main() async {
    // Manually register test1
    await ContainerRegistry.shared.register(
        name: "test1",
        ipAddress: "192.168.65.23",
        network: "default"
    )
    
    // Query it back
    let containers = await ContainerRegistry.shared.getContainersOnNetwork("default")
    print("Found \(containers.count) containers")
    for c in containers {
        print("  \(c.name): \(c.ipAddress)")
    }
}

await main()
