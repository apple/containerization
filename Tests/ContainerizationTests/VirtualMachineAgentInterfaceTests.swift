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

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing

@testable import Containerization

/// Covers the guest-side interface setup that `Interface.ipv4Address` becoming optional
/// made reachable: an interface with no static address, and the routing decisions that
/// follow from it.
struct VirtualMachineAgentInterfaceTests {

    private struct TestInterface: Interface {
        var ipv4Address: CIDRv4?
        var ipv4Gateway: IPv4Address?
        var ipv6Address: CIDRv6?
        var ipv6Gateway: IPv6Address?
        var macAddress: MACAddress?
        var mtu: UInt32 = 1500
    }

    @Test func addressLessInterfaceComesUpWithoutAddressOrRoute() async throws {
        let agent = RecordingAgent()
        let iface = TestInterface()

        try await agent.setupInterface(iface, name: "eth0", setDefaultRoute: true, logger: nil)

        #expect(await agent.addressAdds.isEmpty)
        #expect(await agent.defaultRoutes.isEmpty)
        #expect(await agent.ups == ["eth0"])
    }

    @Test func staticInterfaceGetsItsAddressAndDefaultRoute() async throws {
        let agent = RecordingAgent()
        let iface = TestInterface(
            ipv4Address: try CIDRv4("10.0.0.2/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1")
        )

        try await agent.setupInterface(iface, name: "eth0", setDefaultRoute: true, logger: nil)

        #expect(await agent.addressAdds.count == 1)
        #expect(await agent.addressAdds.first?.ipv4Address == (try CIDRv4("10.0.0.2/24")))
        #expect(await agent.defaultRoutes.count == 1)
        #expect(await agent.defaultRoutes.first?.ipv4Gateway == (try IPv4Address("10.0.0.1")))
    }

    /// `setDefaultRoute` is decided by the caller, but an address-less interface has no
    /// address to install a route from, so it must not install one even when asked.
    @Test func addressLessInterfaceInstallsNoRouteEvenWhenAsked() async throws {
        let agent = RecordingAgent()
        let iface = TestInterface(ipv4Gateway: try IPv4Address("10.0.0.1"))

        try await agent.setupInterface(iface, name: "eth0", setDefaultRoute: true, logger: nil)

        #expect(await agent.defaultRoutes.isEmpty)
        #expect(await agent.linkRoutes.isEmpty)
    }

    /// `InterfaceAddress` requires an IPv4 address, so a v6-only interface cannot be
    /// configured. Refusing beats bringing the link up silently unaddressed.
    @Test func v6WithoutV4IsRejected() async throws {
        let agent = RecordingAgent()
        let iface = TestInterface(ipv6Address: try CIDRv6("fd00::2/64"))

        await #expect {
            try await agent.setupInterface(iface, name: "eth0", setDefaultRoute: false, logger: nil)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.code == .unsupported && error.description.contains("IPv6 address but no IPv4 address")
        }

        #expect(await agent.ups.isEmpty)
    }

    @Test func interfaceMTUIsAppliedWhenBringingTheLinkUp() async throws {
        let agent = RecordingAgent()
        let iface = TestInterface(mtu: 1400)

        try await agent.setupInterface(iface, name: "eth0", setDefaultRoute: false, logger: nil)

        #expect(await agent.upMTUs == [1400])
    }
}

/// Records the networking calls `setupInterface` makes. Everything outside the networking
/// surface is unreachable from `setupInterface` and reports `.unsupported`, matching the
/// contract in `VirtualMachineAgent`.
private actor RecordingAgent: VirtualMachineAgent {
    private(set) var ups: [String] = []
    private(set) var upMTUs: [UInt32] = []
    private(set) var addressAdds: [InterfaceAddress] = []
    private(set) var linkRoutes: [LinkRoute] = []
    private(set) var defaultRoutes: [DefaultRoute] = []

    func up(name: String, mtu: UInt32?) async throws {
        ups.append(name)
        if let mtu {
            upMTUs.append(mtu)
        }
    }

    func addressAdd(name: String, address: InterfaceAddress) async throws {
        addressAdds.append(address)
    }

    func routeAddLink(name: String, route: LinkRoute) async throws {
        linkRoutes.append(route)
    }

    func routeAddDefault(name: String, route: DefaultRoute) async throws {
        defaultRoutes.append(route)
    }

    private func unsupported(_ operation: String) -> ContainerizationError {
        ContainerizationError(.unsupported, message: operation)
    }

    func standardSetup() async throws { throw unsupported("standardSetup") }
    func close() async throws {}
    func down(name: String) async throws { throw unsupported("down") }
    func configureDNS(config: DNS, location: String) async throws { throw unsupported("configureDNS") }
    func filesystemOperation(operation: FilesystemOperation, path: String) async throws { throw unsupported("filesystemOperation") }
    func getenv(key: String) async throws -> String { throw unsupported("getenv") }
    func setenv(key: String, value: String) async throws { throw unsupported("setenv") }
    func mount(_ mount: ContainerizationOCI.Mount) async throws { throw unsupported("mount") }
    func umount(path: String, flags: Int32) async throws { throw unsupported("umount") }
    func mkdir(path: String, all: Bool, perms: UInt32) async throws { throw unsupported("mkdir") }
    func kill(pid: Int32, signal: Int32) async throws -> Int32 { throw unsupported("kill") }

    func createProcess(
        id: String,
        containerID: String?,
        stdinPort: UInt32?,
        stdoutPort: UInt32?,
        stderrPort: UInt32?,
        ociRuntimePath: String?,
        configuration: ContainerizationOCI.Spec,
        options: Data?
    ) async throws { throw unsupported("createProcess") }

    func startProcess(id: String, containerID: String?) async throws -> Int32 { throw unsupported("startProcess") }
    func signalProcess(id: String, containerID: String?, signal: Int32) async throws { throw unsupported("signalProcess") }
    func resizeProcess(id: String, containerID: String?, columns: UInt32, rows: UInt32) async throws { throw unsupported("resizeProcess") }
    func waitProcess(id: String, containerID: String?, timeoutInSeconds: Int64?) async throws -> Containerization.ExitStatus { throw unsupported("waitProcess") }
    func deleteProcess(id: String, containerID: String?) async throws { throw unsupported("deleteProcess") }
}
