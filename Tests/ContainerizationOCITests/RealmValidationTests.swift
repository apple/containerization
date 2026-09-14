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

import Foundation
import Testing

@testable import ContainerizationOCI

struct RealmValidationTests {
    struct TestCase: Sendable, CustomStringConvertible {
        let registry: String
        let scheme: String
        let port: Int?
        let realm: String
        let accepted: Bool

        var description: String { "\(scheme)://\(registry)\(port.map { ":\($0)" } ?? "") -> \(realm)" }
    }

    private static let testCases: [TestCase] = [
        .init(registry: "registry.example.com", scheme: "https", port: nil, realm: "https://auth.example.com/token", accepted: true),
        .init(registry: "ghcr.io", scheme: "https", port: nil, realm: "https://ghcr.io/token", accepted: true),
        .init(registry: "localhost", scheme: "https", port: 5000, realm: "https://localhost:5000/token", accepted: true),
        .init(registry: "127.0.0.1", scheme: "https", port: nil, realm: "https://127.0.0.1/token", accepted: true),
        // Different registrable domain.
        .init(registry: "registry.example.com", scheme: "https", port: nil, realm: "https://auth.attacker.com/token", accepted: false),
        // Suffix, not a label boundary.
        .init(registry: "registry.example.com", scheme: "https", port: nil, realm: "https://notexample.com/token", accepted: false),
        // Cleartext on either endpoint.
        .init(registry: "registry.example.com", scheme: "http", port: nil, realm: "https://auth.example.com/token", accepted: false),
        .init(registry: "registry.example.com", scheme: "https", port: nil, realm: "http://auth.example.com/token", accepted: false),
        // Unqualified and IP hosts get no domain relationship.
        .init(registry: "localhost", scheme: "https", port: 5000, realm: "https://localhost:6000/token", accepted: false),
        .init(registry: "localhost", scheme: "https", port: nil, realm: "https://auth.example.com/token", accepted: false),
        .init(registry: "127.0.0.1", scheme: "https", port: nil, realm: "https://127.0.0.2/token", accepted: false),
        .init(registry: "127.0.0.1", scheme: "https", port: nil, realm: "https://0.0.1/token", accepted: false),
        // Relative realms have no host at all.
        .init(registry: "registry.example.com", scheme: "https", port: nil, realm: "/token", accepted: false),
    ]

    @Test(arguments: testCases)
    func validateRealm(testCase: TestCase) throws {
        let client = RegistryClient(host: testCase.registry, scheme: testCase.scheme, port: testCase.port)
        let realm = try #require(URLComponents(string: testCase.realm))
        if testCase.accepted {
            try client.validateRealm(realm)
        } else {
            #expect(throws: RegistryClient.Error.self) { try client.validateRealm(realm) }
        }
    }

    @Test func insecureRegistryChallengeRejected() throws {
        let client = RegistryClient(host: "registry.example.com", scheme: "http")
        let challenge = #"Bearer realm="https://auth.example.com/token",service="registry.example.com""#
        #expect(throws: RegistryClient.Error.self) { try client.createTokenRequest(parsing: [challenge]) }
    }
}
