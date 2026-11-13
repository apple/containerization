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

struct RegistryClientProxyTests {
    @Test("Proxy credentials in the URL are sent as Basic proxy authorization")
    func credentialsBecomeProxyAuthorization() throws {
        let url = try #require(URL(string: "http://repro:secret@127.0.0.1:18080"))
        let proxy = try #require(RegistryClient.httpProxy(for: url))
        #expect(proxy.host == "127.0.0.1")
        #expect(proxy.port == 18080)
        #expect(proxy.authorization == .basic(username: "repro", password: "secret"))
    }

    @Test("Percent-encoded proxy credentials are decoded")
    func percentEncodedCredentialsAreDecoded() throws {
        let url = try #require(URL(string: "http://user%40corp:p%3Ass%40word@proxy.local:3128"))
        let proxy = try #require(RegistryClient.httpProxy(for: url))
        #expect(proxy.authorization == .basic(username: "user@corp", password: "p:ss@word"))
    }

    @Test("A user without a password gets an empty password")
    func userWithoutPassword() throws {
        let url = try #require(URL(string: "http://repro@proxy.local:3128"))
        let proxy = try #require(RegistryClient.httpProxy(for: url))
        #expect(proxy.authorization == .basic(username: "repro", password: ""))
    }

    @Test("A proxy URL without credentials sends no authorization")
    func noCredentials() throws {
        let url = try #require(URL(string: "http://proxy.local"))
        let proxy = try #require(RegistryClient.httpProxy(for: url))
        #expect(proxy.port == 80)
        #expect(proxy.authorization == nil)
    }
}
