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

/// `service` is a Docker registry convention, not a requirement of RFC 6750 section 3, so a
/// conforming registry may omit it from the Bearer challenge. `parseWWWAuthenticateHeaders` has
/// always modelled it as optional — see `AuthChallengeTests` — but `createTokenRequest` used to
/// reject a challenge without it, which locked out every registry that omits it.
struct TokenRequestServiceTests {
    /// Google Artifact Registry's actual challenge, verbatim: realm only, no `service`.
    private static let artifactRegistryChallenge = #"Bearer realm="https://us-central1-docker.pkg.dev/v2/token""#

    /// Docker Hub's challenge, which does carry `service`.
    private static let dockerHubChallenge =
        #"Bearer realm="https://auth.docker.io/token",service="registry.docker.io""#

    @Test
    func acceptsChallengeWithoutService() throws {
        let client = RegistryClient(host: "us-central1-docker.pkg.dev", scheme: "https")
        let request = try client.createTokenRequest(parsing: [Self.artifactRegistryChallenge])

        #expect(request.realm == "https://us-central1-docker.pkg.dev/v2/token")
        #expect(request.service == nil)
    }

    @Test
    func preservesServiceWhenPresent() throws {
        let client = RegistryClient(host: "registry-1.docker.io", scheme: "https")
        let request = try client.createTokenRequest(parsing: [Self.dockerHubChallenge])

        #expect(request.service == "registry.docker.io")
    }

    /// `realm` stays mandatory — without it there is nowhere to send the token request.
    @Test
    func stillRejectsChallengeWithoutRealm() throws {
        let client = RegistryClient(host: "registry.example.com", scheme: "https")

        #expect(throws: (any Error).self) {
            try client.createTokenRequest(parsing: [#"Bearer service="registry.example.com""#])
        }
    }
}
