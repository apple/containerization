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

@testable import Containerization

struct DNSTests {

    @Test func dnsResolvConfWithAllFields() {
        let dns = DNS(
            nameservers: ["8.8.8.8", "1.1.1.1"],
            domain: "example.com",
            searchDomains: ["internal.com", "test.com"],
            options: ["ndots:2", "timeout:1"]
        )

        let expected = "nameserver 8.8.8.8\nnameserver 1.1.1.1\ndomain example.com\nsearch internal.com test.com\noptions ndots:2 timeout:1\n"
        #expect(dns.resolvConf == expected)
    }

    @Test func dnsResolvConfWithEmptyFields() {
        let dns = DNS(
            nameservers: [],
            domain: nil,
            searchDomains: [],
            options: []
        )

        // Should return empty string when all fields are empty
        #expect(dns.resolvConf == "")
    }

    @Test func dnsResolvConfWithOnlyNameservers() {
        let dns = DNS(nameservers: ["8.8.8.8"])

        let expected = "nameserver 8.8.8.8\n"
        #expect(dns.resolvConf == expected)
    }
}
