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

#if os(Linux)
import ArgumentParser
import Containerization
import ContainerizationExtras
import Foundation

extension Application {
    struct Bridge: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bridge",
            abstract: "Manage the host bridge used by `cctl run` for container networking",
            subcommands: [Create.self, Delete.self]
        )

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "create",
                abstract: "Create (or reconfigure idempotently) the host bridge + NAT plumbing"
            )

            @Option(name: .long, help: "Bridge interface name")
            var name: String = "cz0"

            @Option(name: .long, help: "IPv4 subnet in CIDR form")
            var subnet: String = "192.168.64.0/24"

            @Option(name: .long, help: "Host-side IPv4 on the bridge (defaults to subnet.lower+1)")
            var gateway: String?

            @Option(name: .long, help: "Egress interface for MASQUERADE (default: auto-detect from default route)")
            var egress: String?

            @Option(name: .long, help: "Bridge MTU")
            var mtu: UInt32 = 1500

            @Flag(
                name: .customLong("enable-nat"),
                help:
                    "Program iptables MASQUERADE/FORWARD and enable net.ipv4.ip_forward so containers reach the outside network. Off by default — host firewall policy is left untouched."
            )
            var enableNAT: Bool = false

            func run() async throws {
                let cidr = try CIDRv4(subnet)
                let gw = try gateway.map { try IPv4Address($0) }
                let mgr = try BridgeManager.make(
                    name: name,
                    subnet: cidr,
                    gateway: gw,
                    mtu: mtu,
                    egressInterface: egress,
                    enableNAT: enableNAT,
                    logger: log
                )
                try mgr.create()
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "delete",
                abstract: "Remove the bridge and revert the host plumbing this tool added"
            )

            @Option(name: .long, help: "Bridge interface name")
            var name: String = "cz0"

            @Option(name: .long, help: "IPv4 subnet in CIDR form")
            var subnet: String = "192.168.64.0/24"

            func run() async throws {
                let cidr = try CIDRv4(subnet)
                let mgr = try BridgeManager.make(name: name, subnet: cidr, logger: log)
                try mgr.delete()
            }
        }
    }
}
#endif
