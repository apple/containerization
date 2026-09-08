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

import NIOHTTP1
import Testing

@testable import ContainerizationOCI

struct RegistryRequestHeaderTests {
    @Test func defaultUserAgentIsSet() throws {
        let client = RegistryClient(host: "registry.example.com")
        let request = client.buildRequest(url: "https://registry.example.com/v2/", method: .GET, headers: nil)
        #expect(request.headers["User-Agent"] == ["containerization-registry-client"])
    }

    @Test func customClientIDBecomesUserAgent() throws {
        let client = RegistryClient(host: "registry.example.com", clientID: "my-tool/1.2.3")
        let request = client.buildRequest(url: "https://registry.example.com/v2/", method: .GET, headers: nil)
        #expect(request.headers["User-Agent"] == ["my-tool/1.2.3"])
    }

    @Test func callerSuppliedUserAgentOverridesDefault() throws {
        let client = RegistryClient(host: "registry.example.com")
        let request = client.buildRequest(
            url: "https://registry.example.com/v2/",
            method: .GET,
            headers: [("User-Agent", "override/9.9")]
        )
        // The default must not be duplicated when the caller provides one.
        #expect(request.headers["User-Agent"] == ["override/9.9"])
    }

    @Test func userAgentCoexistsWithOtherHeaders() throws {
        let client = RegistryClient(host: "registry.example.com")
        let request = client.buildRequest(
            url: "https://registry.example.com/v2/",
            method: .PUT,
            headers: [("Content-Type", "application/octet-stream")]
        )
        #expect(request.headers["User-Agent"] == ["containerization-registry-client"])
        #expect(request.headers["Content-Type"] == ["application/octet-stream"])
    }
}
