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

//

import Foundation
import Testing

@testable import ContainerizationOS

struct KeychainQueryTests {
    let id = "com.example.container-testing-keychain"
    let domain = "testing-keychain.example.com"
    let user = "containerization-test"

    let kq = KeychainQuery()

    @Test(.enabled(if: !isCI))
    func keychainQuery() throws {
        defer { try? kq.delete(id: id, host: domain) }

        do {
            try kq.save(id: id, host: domain, user: user, token: "foobar")
            #expect(try kq.exists(id: id, host: domain))

            let fetched = try kq.get(id: id, host: domain)
            let result = try #require(fetched)
            #expect(result.account == user)
            #expect(result.data == "foobar")
        } catch KeychainQuery.Error.unhandledError(status: -25308) {
            // ignore errSecInteractionNotAllowed
        }
    }

    private static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }
}
