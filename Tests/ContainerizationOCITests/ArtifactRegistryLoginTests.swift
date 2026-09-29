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

/// Live authentication against Google Artifact Registry, whose multi-region endpoints answer an
/// unauthenticated `GET /v2/` with a challenge that carries `realm` but no `service`:
///
///     www-authenticate: Bearer realm="https://europe-docker.pkg.dev/v2/token"
///
/// Exercises the full challenge -> token exchange -> retry path, which the offline cases in
/// `AuthChallengeTests` cannot reach.
///
/// Opt in by supplying a token; the test is skipped otherwise:
///
///     GAR_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
///       swift test --filter ArtifactRegistryLoginTests
///
struct ArtifactRegistryLoginTests {
    private static var accessToken: String? {
        guard let token = ProcessInfo.processInfo.environment["GAR_ACCESS_TOKEN"], !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Override with `GAR_HOST` to test a regional endpoint instead.
    private static var host: String {
        ProcessInfo.processInfo.environment["GAR_HOST"] ?? "europe-docker.pkg.dev"
    }

    static var hasAccessToken: Bool { accessToken != nil }

    /// The registry's challenge really does omit `service`, so this test covers the patched path
    /// rather than silently passing through the ordinary one.
    @Test func multiRegionChallengeOmitsService() async throws {
        let client = RegistryClient(host: Self.host, scheme: "https")

        let request = try client.createTokenRequest(parsing: [#"Bearer realm="https://\#(Self.host)/v2/token""#])

        #expect(request.service == nil)
        #expect(!RegistryClient.tokenQueryItems(for: request).contains { $0.name == "service" })
    }

    @Test(.enabled(if: hasAccessToken))
    func loginSucceedsAgainstArtifactRegistry() async throws {
        let token = try #require(Self.accessToken)
        let client = RegistryClient(
            host: Self.host,
            scheme: "https",
            authentication: BasicAuthentication(username: "oauth2accesstoken", password: token)
        )

        try await client.ping()
    }
}
