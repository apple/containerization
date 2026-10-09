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

struct InterfaceTests {

    /// A minimal `Interface` conformer that only sets the IPv4 surface, relying on the
    /// protocol's default extensions to fill in `ipv6Address`, `ipv6Gateway`, and `mtu`.
    private struct V4OnlyInterface: Interface {
        let ipv4Address: CIDRv4
        let ipv4Gateway: IPv4Address?
        let macAddress: MACAddress?
    }

    @Test func interfaceProtocolV6Defaults() throws {
        let i = V4OnlyInterface(
            ipv4Address: try CIDRv4("10.0.0.2/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"),
            macAddress: nil)
        #expect(i.ipv6Address == nil)
        #expect(i.ipv6Gateway == nil)
        #expect(i.mtu == 1500)
    }

    @Test func natInterfaceRoundTripsV6Fields() throws {
        let nat = NATInterface(
            ipv4Address: try CIDRv4("10.0.0.2/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"),
            ipv6Address: try CIDRv6("fd00::2/64"),
            ipv6Gateway: try IPv6Address("fd00::1"))
        #expect(nat.ipv6Address == (try CIDRv6("fd00::2/64")))
        #expect(nat.ipv6Gateway == (try IPv6Address("fd00::1")))
    }

    @Test func natInterfaceV6FieldsDefaultToNil() throws {
        let nat = NATInterface(
            ipv4Address: try CIDRv4("10.0.0.2/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"))
        #expect(nat.ipv6Address == nil)
        #expect(nat.ipv6Gateway == nil)
    }

    /// Records the routing calls `setupInterface` makes so the routing decisions can be
    /// asserted without booting a sandbox. Everything outside the networking surface is
    /// unsupported, which is what the protocol asks unimplemented operations to report.
    private actor RecordingAgent: VirtualMachineAgent {
        private(set) var addresses: [InterfaceAddress] = []
        private(set) var linkRoutes: [LinkRoute] = []
        private(set) var defaultRoutes: [DefaultRoute] = []
        private(set) var linksBroughtUp: [String] = []

        func addressAdd(name: String, address: InterfaceAddress) async throws {
            addresses.append(address)
        }

        func up(name: String, mtu: UInt32?) async throws {
            linksBroughtUp.append(name)
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
        func close() async throws { throw unsupported("close") }
        func filesystemOperation(operation: FilesystemOperation, path: String) async throws { throw unsupported("filesystemOperation") }
        func getenv(key: String) async throws -> String { throw unsupported("getenv") }
        func setenv(key: String, value: String) async throws { throw unsupported("setenv") }
        func mount(_ mount: ContainerizationOCI.Mount) async throws { throw unsupported("mount") }
        func umount(path: String, flags: Int32) async throws { throw unsupported("umount") }
        func mkdir(path: String, all: Bool, perms: UInt32) async throws { throw unsupported("mkdir") }
        func kill(pid: Int32, signal: Int32) async throws -> Int32 { throw unsupported("kill") }
        func down(name: String) async throws { throw unsupported("down") }
        func configureDNS(config: DNS, location: String) async throws { throw unsupported("configureDNS") }

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

    /// `Interface` documents a nil gateway as "no default route", so an interface with
    /// neither a v4 nor a v6 gateway must not get one. Installing it anyway leaves the
    /// guest with an on-link default route that makes every destination look local.
    @Test func noDefaultRouteWhenBothGatewaysAreNil() async throws {
        let agent = RecordingAgent()
        let interface = V4OnlyInterface(
            ipv4Address: try CIDRv4("172.16.0.3/24"),
            ipv4Gateway: nil,
            macAddress: nil)

        try await agent.setupInterface(interface, name: "eth0", setDefaultRoute: true, logger: nil)

        #expect(await agent.linksBroughtUp == ["eth0"])
        #expect(await agent.addresses.count == 1)
        #expect(await agent.defaultRoutes.isEmpty)
        #expect(await agent.linkRoutes.isEmpty)
    }

    @Test func defaultRouteInstalledForIPv4Gateway() async throws {
        let agent = RecordingAgent()
        let interface = V4OnlyInterface(
            ipv4Address: try CIDRv4("172.16.0.3/24"),
            ipv4Gateway: try IPv4Address("172.16.0.1"),
            macAddress: nil)

        try await agent.setupInterface(interface, name: "eth0", setDefaultRoute: true, logger: nil)

        let routes = await agent.defaultRoutes
        #expect(routes.count == 1)
        #expect(routes.first?.ipv4Gateway == (try IPv4Address("172.16.0.1")))
        #expect(routes.first?.ipv6Gateway == nil)
    }

    /// A v6-only gateway still needs the default route, so the nil v4 gateway alone must
    /// not suppress it.
    @Test func defaultRouteInstalledForIPv6OnlyGateway() async throws {
        let agent = RecordingAgent()
        let interface = NATInterface(
            ipv4Address: try CIDRv4("192.0.2.2/24"),
            ipv4Gateway: nil,
            ipv6Address: try CIDRv6("fd00::2/64"),
            ipv6Gateway: try IPv6Address("fd00::1"))

        try await agent.setupInterface(interface, name: "eth0", setDefaultRoute: true, logger: nil)

        let routes = await agent.defaultRoutes
        #expect(routes.count == 1)
        #expect(routes.first?.ipv4Gateway == nil)
        #expect(routes.first?.ipv6Gateway == (try IPv6Address("fd00::1")))
    }

    @Test func noDefaultRouteWhenNotRequested() async throws {
        let agent = RecordingAgent()
        let interface = V4OnlyInterface(
            ipv4Address: try CIDRv4("172.16.0.3/24"),
            ipv4Gateway: try IPv4Address("172.16.0.1"),
            macAddress: nil)

        try await agent.setupInterface(interface, name: "eth0", setDefaultRoute: false, logger: nil)

        #expect(await agent.defaultRoutes.isEmpty)
    }
}
