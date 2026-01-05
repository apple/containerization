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

@testable import ContainerizationExtras

struct ProxyUtilsTests {

    @Test("HTTP proxy resolution")
    func testHttpProxy() {
        let env = ["http_proxy": "http://proxy.local:8080"]
        let proxy = ProxyUtils.proxyFromEnvironment(scheme: "http", host: "example.com", env: env)
        #expect(proxy?.absoluteString == "http://proxy.local:8080")
    }

    @Test("HTTP proxy miss")
    func testHttpProxyMiss() {
        let env = ["http_proxy": "http://proxy.local:8080"]
        let proxy = ProxyUtils.proxyFromEnvironment(scheme: "https", host: "secure.com", env: env)
        #expect(proxy?.absoluteString == nil)
    }

    @Test("HTTPS proxy resolution")
    func testHttpsProxy() {
        let env = ["https_proxy": "https://secureproxy.local:8443"]
        let proxy = ProxyUtils.proxyFromEnvironment(scheme: "https", host: "secure.com", env: env)
        #expect(proxy?.absoluteString == "https://secureproxy.local:8443")
    }

    @Test("HTTPS proxy miss")
    func testHttpsProxyMiss() {
        let env = ["https_proxy": "https://secureproxy.local:8443"]
        let proxy = ProxyUtils.proxyFromEnvironment(scheme: "http", host: "example.com", env: env)
        #expect(proxy?.absoluteString == nil)
    }

    @Test("NO_PROXY exact match")
    func testNoProxyExactMatch() {
        let env = [
            "http_proxy": "http://proxy.local:8080",
            "NO_PROXY": "example.com",
        ]
        let proxy = ProxyUtils.proxyFromEnvironment(scheme: "http", host: "example.com", env: env)
        #expect(proxy == nil)
    }

    @Test("Uppercase HTTP_PROXY is respected")
    func testUppercaseHttpProxy() {
        let env = ["HTTP_PROXY": "http://upper.local:8081"]
        let proxy = ProxyUtils.proxyFromEnvironment(scheme: "http", host: "upper.com", env: env)
        #expect(proxy?.absoluteString == "http://upper.local:8081")
    }

    @Test("Lowercase no_proxy is respected")
    func testLowercaseNoProxy() {
        let env = [
            "http_proxy": "http://proxy.local:8080",
            "no_proxy": "lower.com",
        ]
        let proxy = ProxyUtils.proxyFromEnvironment(scheme: "http", host: "lower.com", env: env)
        #expect(proxy == nil)
    }

    @Test("Uppercase HTTP_PROXY overrides lowercase http_proxy")
    func testUppercaseOverridesLowercaseHttp() {
        let env = [
            "http_proxy": "http://lower.local:8080",
            "HTTP_PROXY": "http://upper.local:8081",
        ]
        let proxy = ProxyUtils.proxyFromEnvironment(scheme: "http", host: "example.com", env: env)
        #expect(proxy?.absoluteString == "http://upper.local:8081")
    }

    @Test("Uppercase HTTPS_PROXY overrides lowercase https_proxy")
    func testUppercaseOverridesLowercaseHttps() {
        let env = [
            "https_proxy": "https://lower.local:8443",
            "HTTPS_PROXY": "https://upper.local:8444",
        ]
        let proxy = ProxyUtils.proxyFromEnvironment(scheme: "https", host: "secure.com", env: env)
        #expect(proxy?.absoluteString == "https://upper.local:8444")
    }

    @Test("Uppercase NO_PROXY overrides lowercase no_proxy")
    func testUppercaseOverridesLowercaseNoProxy() {
        let env = [
            "http_proxy": "http://proxy.local:8080",
            "no_proxy": "foo.com",
            "NO_PROXY": "bar.com",
        ]
        let proxyFoo = ProxyUtils.proxyFromEnvironment(scheme: "http", host: "foo.com", env: env)
        let proxyBar = ProxyUtils.proxyFromEnvironment(scheme: "https", host: "bar.com", env: env)

        #expect(proxyFoo != nil)
        #expect(proxyBar == nil)
    }
}
