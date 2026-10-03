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

import Testing

@testable import ContainerizationOCI

@Suite("String.isDigest Tests")
struct StringIsDigestTests {
    @Test(
        "recognizes digest-shaped strings",
        arguments: [
            "sha256:\(String(repeating: "a", count: 64))",
            "sha256:\(String(repeating: "A", count: 64))",
            "sha256:\(String(repeating: "aA", count: 32))",
        ])
    func recognizesDigests(_ input: String) {
        #expect(input.isDigest)
    }

    @Test(
        "rejects everything that isn't a well-formed sha256 digest",
        arguments: [
            "latest",
            "v1.2.3",
            "sha256-\(String(repeating: "a", count: 64))",  // referrers-tag-fallback shape: must stay exempt from the pin check
            "sha256:\(String(repeating: "a", count: 63))",  // too short
            "sha256:\(String(repeating: "a", count: 65))",  // too long
            "sha256:\(String(repeating: "g", count: 64))",  // non-hex characters
            "sha512:\(String(repeating: "a", count: 128))",  // unsupported algorithm
            "",
        ])
    func rejectsNonDigests(_ input: String) {
        #expect(!input.isDigest)
    }
}
