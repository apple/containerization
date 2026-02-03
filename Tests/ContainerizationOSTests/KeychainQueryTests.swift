//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

@testable import ContainerizationOS

struct KeychainQueryTests {
    let securityDomain = "com.example.container-testing-keychain"
    let hostname = "testing-keychain.example.com"
    let user = "containerization-test"

    let kq = KeychainQuery()

    @Test(.enabled(if: !isCI))
    func keychainQuery() throws {
        defer { try? kq.delete(securityDomain: securityDomain, hostname: hostname) }

        do {
            try kq.save(securityDomain: securityDomain, hostname: hostname, user: user, token: "foobar")
            #expect(try kq.exists(securityDomain: securityDomain, hostname: hostname))

            let fetched = try kq.get(securityDomain: securityDomain, hostname: hostname)
            let result = try #require(fetched)
            #expect(result.account == user)
            #expect(result.data == "foobar")
        } catch KeychainQuery.Error.unhandledError(status: -25308) {
            // ignore errSecInteractionNotAllowed
        }
    }

    @Test(.enabled(if: !isCI))
    func list() throws {
        let hostname1 = "testing-1-keychain.example.com"
        let hostname2 = "testing-2-keychain.example.com"

        defer {
            try? kq.delete(securityDomain: securityDomain, hostname: hostname1)
            try? kq.delete(securityDomain: securityDomain, hostname: hostname2)
        }

        do {
            try kq.save(securityDomain: securityDomain, hostname: hostname1, user: user, token: "foobar")
            try kq.save(securityDomain: securityDomain, hostname: hostname2, user: user, token: "foobar")

            let entries = try kq.list(securityDomain: securityDomain)

            // Verify that both hostnames exist
            let hostnames = entries.map { $0.hostname }
            #expect(hostnames.contains(hostname1))
            #expect(hostnames.contains(hostname2))

            // Verify that the accounts exist
            for entry in entries {
                #expect(entry.username == user)
            }
        } catch KeychainQuery.Error.unhandledError(status: -25308) {
            // ignore errSecInteractionNotAllowed
        }
    }

    private static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }
}
