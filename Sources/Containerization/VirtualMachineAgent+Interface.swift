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

import ContainerizationExtras
import Logging

extension VirtualMachineAgent {
    /// Configure a single network interface inside the sandbox: assign addresses,
    /// bring the link up, and (when requested) install the link/default routes.
    func setupInterface(
        _ interface: any Interface,
        name: String,
        setDefaultRoute: Bool,
        logger: Logger?
    ) async throws {
        let ipv4Address = interface.ipv4Address
        let ipv4Gateway = interface.ipv4Gateway
        let ipv6Gateway = interface.ipv6Gateway
        let ipv6Address = interface.ipv6Address

        if let ipv4Address {
            logger?.debug("setting up interface \(name) with v4 \(ipv4Address) v6 \(interface.ipv6Address?.description ?? "<none>")")
            try await addressAdd(
                name: name,
                address: .init(ipv4Address: ipv4Address, ipv6Address: interface.ipv6Address)
            )
        }
        try await up(name: name, mtu: interface.mtu)

        guard setDefaultRoute else { return }
        guard let ipv4Address else { return }

        let needsIPv4LinkRoute: Bool
        if let ipv4Gateway {
            needsIPv4LinkRoute = !ipv4Address.contains(ipv4Gateway)
        } else {
            needsIPv4LinkRoute = false
        }

        let needsIPv6LinkRoute: Bool
        if let ipv6Gateway, let ipv6Address {
            needsIPv6LinkRoute = !ipv6Address.contains(ipv6Gateway)
        } else {
            needsIPv6LinkRoute = false
        }

        if needsIPv4LinkRoute, let ipv4Gateway {
            logger?.debug("v4 gateway \(ipv4Gateway) is outside subnet \(ipv4Address), adding a route first")
        }
        if needsIPv6LinkRoute, let ipv6Gateway, let ipv6Address {
            logger?.debug("v6 gateway \(ipv6Gateway) is outside subnet \(ipv6Address), adding a route first")
        }

        if needsIPv4LinkRoute || needsIPv6LinkRoute {
            try await routeAddLink(
                name: name,
                route: .init(
                    ipv4Destination: needsIPv4LinkRoute ? ipv4Gateway : nil,
                    ipv4Source: needsIPv4LinkRoute ? ipv4Address.address : nil,
                    ipv6Destination: needsIPv6LinkRoute ? ipv6Gateway : nil,
                    ipv6Source: needsIPv6LinkRoute ? ipv6Address?.address : nil
                )
            )
        }

        if ipv4Gateway == nil && ipv6Gateway == nil {
            logger?.debug("no gateway for \(name)")
        }
        try await routeAddDefault(
            name: name,
            route: .init(ipv4Gateway: ipv4Gateway, ipv6Gateway: ipv6Gateway)
        )
    }
}
