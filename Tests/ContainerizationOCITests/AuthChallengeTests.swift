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

@testable import ContainerizationOCI

struct AuthChallengeTests {
    internal struct TestCase: Sendable {
        let input: String
        let expected: AuthenticateChallenge
    }

    private static let testCases: [TestCase] = [
        .init(
            input: """
                Bearer realm="https://domain.io/token",service="domain.io",scope="repository:user/image:pull"
                """,
            expected: .init(type: "Bearer", realm: "https://domain.io/token", service: "domain.io", scope: "repository:user/image:pull", error: nil)),
        .init(
            input: """
                Bearer realm="https://foo-bar-registry.com/auth",service="Awesome Registry"
                """,
            expected: .init(type: "Bearer", realm: "https://foo-bar-registry.com/auth", service: "Awesome Registry", scope: nil, error: nil)),
        .init(
            input: """
                Bearer realm="users.example.com", scope="create delete"
                """,
            expected: .init(type: "Bearer", realm: "users.example.com", service: nil, scope: "create delete", error: nil)),
        .init(
            input: """
                Bearer realm="https://auth.server.io/token",service="registry.server.io"
                """,
            expected: .init(type: "Bearer", realm: "https://auth.server.io/token", service: "registry.server.io", scope: nil, error: nil)),

    ]

    @Test(arguments: testCases)
    func parseAuthHeader(testCase: TestCase) throws {
        let challenges = RegistryClient.parseWWWAuthenticateHeaders(headers: [testCase.input])
        #expect(challenges.count == 1)
        #expect(challenges[0] == testCase.expected)
    }
}
