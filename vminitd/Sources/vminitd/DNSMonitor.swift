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

import Containerization
import ContainerizationExtras
import ContainerizationICMP
import Foundation
import Logging
import SystemPackage

private struct IPv6Nameserver {
    let address: IPv6Address
    let expiry: Date
}

actor DNSMonitor {
    private static let maxNameservers = 3

    private var configs: [FilePath: DNS] = [:]

    private var ipv6Nameservers: [IPv6Nameserver] = []

    private let log: Logger

    private let icmpV6Session: ICMPv6Session

    init(log: Logger) throws {
        self.log = log
        self.icmpV6Session = try ICMPv6Session()
    }

    func update(resolvConfPath: FilePath, config: DNS) throws {
        let parentPathname = resolvConfPath.removingLastComponent().string
        try FileManager.default.createDirectory(atPath: parentPathname, withIntermediateDirectories: true)

        let mergedNameservers: [String]
        if config.nameservers.count < Self.maxNameservers {
            mergedNameservers = config.nameservers + ipv6Nameservers.map { $0.address.description }
        } else {
            mergedNameservers = config.nameservers.prefix(2) + ipv6Nameservers.map { $0.address.description }
        }

        let mergedConfig = DNS(
            nameservers: mergedNameservers,
            domain: config.domain,
            searchDomains: config.searchDomains,
            options: config.options
        )

        let text = mergedConfig.resolvConf
        log.debug("updating resolver configuration", metadata: ["path": "\(resolvConfPath)"])
        try text.write(toFile: resolvConfPath.string, atomically: true, encoding: .utf8)
        configs[resolvConfPath] = config
    }

    func run() async throws {
        self.log.info("starting DNS monitor")
        while true {
            let now = Date.now
            let timeInterval =
                ipv6Nameservers
                .map { $0.expiry.timeIntervalSince(now) }
                .compactMap { $0 >= 0 ? $0 : nil }
                .min()
            do {
                if timeInterval == nil {
                    self.log.info("sending router solicitation")
                    try sendRouterSolicitation()
                }
            } catch {
                log.warning("router solicitation send failed", metadata: ["error": "\(error)"])
                try await Task.sleep(for: .seconds(1))
                continue
            }

            do {
                let timeout = Duration.seconds(timeInterval ?? 1.0)
                log.info("awaiting router advertisement", metadata: ["timeoutSecs": "\(timeout)"])
                var lifetimesByAddress = try await getIpv6Nameservers(timeout: timeout)
                var newNameservers: [IPv6Nameserver] = []
                let now = Date.now
                for nameserver in ipv6Nameservers {
                    guard let lifetime = lifetimesByAddress[nameserver.address] else {
                        // No update, carry it over.
                        newNameservers.append(nameserver)
                        continue
                    }

                    // Remove since we're deleting or merging.
                    lifetimesByAddress.removeValue(forKey: nameserver.address)
                    if lifetime == 0 {
                        // Zero lifetime, so delete.
                        continue
                    }

                    // Merge new expiry into existing entry.
                    newNameservers.append(.init(address: nameserver.address, expiry: now.addingTimeInterval(Double(lifetime))))
                }

                // Add remaining entries.
                for (address, lifetime) in lifetimesByAddress {
                    newNameservers.append(.init(address: address, expiry: now.addingTimeInterval(Double(lifetime))))
                }

                self.ipv6Nameservers = newNameservers
            } catch {
                log.warning("router advertisement receive failed", metadata: ["error": "\(error)"])
            }

            do {
                for (resolvConfPath, dns) in configs {
                    log.info("awaiting DNS", metadata: ["path": "\(resolvConfPath)"])
                    try update(resolvConfPath: resolvConfPath, config: dns)
                }
            } catch {
                log.warning("DNS update failed", metadata: ["error": "\(error)"])
            }
        }
    }

    private func sendRouterSolicitation() throws {
        let interface = "eth0"
        guard let linkLayerAddress = MACAddress.fromZone(interface) else {
            throw AddressError.invalidZoneIdentifier
        }
        _ = try icmpV6Session.routerSolicitation(linkLayerAddress: linkLayerAddress, interface: interface)
    }

    private func getIpv6Nameservers(timeout: Duration) async throws -> [IPv6Address: UInt32] {
        var result = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let result = try self.icmpV6Session.recv(
                        type: .routerAdvertisement,
                        timeout: timeout
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        // Parse router advertisement.
        var routerAdvertisement = try RouterAdvertisement()
        let offset = try routerAdvertisement.bindBuffer(&result.bytes, offset: result.offset)

        // Parse options, adding RDNSS server addresses and lifetimes.
        let remainingBytes = result.length - offset
        let options = try result.bytes.parseNDOptions(offset: offset, length: remainingBytes)
        var lifetimesByAddress: [IPv6Address: UInt32] = [:]
        for option in options {
            switch option {
            case .recursiveDNSServer(let lifetime, let addresses):
                addresses.forEach { lifetimesByAddress[$0] = lifetime }
            default:
                continue
            }
        }

        return lifetimesByAddress
    }
}
