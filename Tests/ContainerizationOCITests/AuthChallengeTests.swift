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
        .init(
            input: """
                Basic realm="Registry Realm"
                """,
            expected: .init(type: "Basic", realm: "Registry Realm", service: nil, scope: nil, error: nil)),
        .init(
            input: """
                Bearer realm="https://gcr.io/v2/token",service=gcr.io
                """,
            expected: .init(type: "Bearer", realm: "https://gcr.io/v2/token", service: "gcr.io", scope: nil, error: nil)),
        .init(
            input: """
                Bearer realm="https://us-docker.pkg.dev/v2/token"
                """,
            expected: .init(type: "Bearer", realm: "https://us-docker.pkg.dev/v2/token", service: nil, scope: nil, error: nil)),
    ]

    @Test(arguments: testCases)
    func parseAuthHeader(testCase: TestCase) throws {
        let challenges = RegistryClient.parseWWWAuthenticateHeaders(headers: [testCase.input])
        #expect(challenges.count == 1)
        #expect(challenges[0] == testCase.expected)
    }

    /// `service` is an optional parameter of the Docker token specification, so a challenge that
    /// omits it must still yield a usable token request.
    ///
    /// Regression test: Google Artifact Registry's multi-region endpoints answer an
    /// unauthenticated `GET /v2/` with a challenge carrying only `realm`. Requiring `service`
    /// made `container registry login europe-docker.pkg.dev` fail with
    /// "cannot parse service from WWW-Authenticate header".
    @Test func challengeWithoutServiceIsAccepted() throws {
        let client = RegistryClient(host: "europe-docker.pkg.dev", scheme: "https")
        let challenge = #"Bearer realm="https://europe-docker.pkg.dev/v2/token""#

        let request = try client.createTokenRequest(parsing: [challenge])

        #expect(request.realm == "https://europe-docker.pkg.dev/v2/token")
        #expect(request.service == nil)
    }

    /// A challenge that supplies `service` still round-trips it.
    @Test func challengeWithServiceIsPreserved() throws {
        let client = RegistryClient(host: "registry-1.docker.io", scheme: "https")
        let challenge = #"Bearer realm="https://auth.docker.io/token",service="registry.docker.io""#

        let request = try client.createTokenRequest(parsing: [challenge])

        #expect(request.realm == "https://auth.docker.io/token")
        #expect(request.service == "registry.docker.io")
    }

    /// An absent `service` is not echoed back to the authorization server as an empty parameter.
    @Test func serviceOmittedFromQueryWhenAbsent() throws {
        let request = TokenRequest(realm: "https://europe-docker.pkg.dev/v2/token", service: nil, clientId: "tests", scope: nil)

        let items = RegistryClient.tokenQueryItems(for: request)

        #expect(!items.contains { $0.name == "service" })
        #expect(items.contains { $0.name == "client_id" && $0.value == "tests" })
    }

    /// A present `service`, and the other optional parameters, still reach the query string.
    @Test func serviceIncludedInQueryWhenPresent() throws {
        let request = TokenRequest(
            realm: "https://auth.docker.io/token",
            service: "registry.docker.io",
            clientId: "tests",
            scope: "repository:user/image:pull",
            offlineToken: true
        )

        let items = RegistryClient.tokenQueryItems(for: request)

        #expect(items.first { $0.name == "service" }?.value == "registry.docker.io")
        #expect(items.first { $0.name == "scope" }?.value == "repository:user/image:pull")
        #expect(items.first { $0.name == "offline_token" }?.value == "true")
    }
}
