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

// swiftlint:disable force_cast large_tuple

import ContainerizationError
import Foundation
import Testing

@testable import ContainerizationOCI

@Suite("Reference Parse Tests")
struct ReferenceParseTests {
    internal struct ReferenceParseTestCase: Sendable {
        let input: String
        let domain: String?
        let path: String
        let tag: String?
        let digest: String?
        init(input: String, domain: String? = nil, path: String, tag: String? = nil, digest: String? = nil) {
            self.input = input
            self.domain = domain
            self.path = path
            self.tag = tag
            self.digest = digest
        }
    }

    @Test(arguments: [
        ReferenceParseTestCase(input: "tensorflow/tensorflow", path: "tensorflow/tensorflow"),
        ReferenceParseTestCase(input: "debian", path: "debian"),
        ReferenceParseTestCase(input: "repo_with_underscore", path: "repo_with_underscore"),
        ReferenceParseTestCase(input: "swift5.10:alpine", path: "swift5.10", tag: "alpine"),
        ReferenceParseTestCase(input: "registry.com.with.port:5000/no_tag", domain: "registry.com.with.port:5000", path: "no_tag"),
        ReferenceParseTestCase(input: "registry.com.with.port:5000/name/foo/bar:tag23", domain: "registry.com.with.port:5000", path: "name/foo/bar", tag: "tag23"),
        ReferenceParseTestCase(input: "some-repo-with-dashes/name", path: "some-repo-with-dashes/name"),
        ReferenceParseTestCase(input: "domain.with-dashes/cool-image:foo", domain: "domain.with-dashes", path: "cool-image", tag: "foo"),
        ReferenceParseTestCase(input: "localhost:8080/123:latest", domain: "localhost:8080", path: "123", tag: "latest"),
        ReferenceParseTestCase(
            input: "localhost/123@sha256:\(String(repeating: "a", count: 64))", domain: "localhost", path: "123", digest: "sha256:\(String(repeating: "a", count: 64))"),
        ReferenceParseTestCase(
            input: "registry.com.with.port:1254/foo/bar/baz@sha256:\(String(repeating: "abcd", count: 16))", domain: "registry.com.with.port:1254", path: "foo/bar/baz",
            digest: "sha256:\(String(repeating: "abcd", count: 16))"),
        ReferenceParseTestCase(input: "192.168.1.1:5544/local/swift:6.0", domain: "192.168.1.1:5544", path: "local/swift", tag: "6.0"),
        ReferenceParseTestCase(input: "[abc12::4]:5683/swift", domain: "[abc12::4]:5683", path: "swift"),
    ])
    func validReferenceParse(testCase: ReferenceParseTestCase) async throws {
        #expect(throws: Never.self) {
            let parsed = try Reference.parse(testCase.input)
            #expect(parsed.path == testCase.path)
            #expect(parsed.domain == testCase.domain)
            #expect(parsed.digest == testCase.digest)
            #expect(parsed.tag == testCase.tag)
        }
    }

    @Test(arguments: [
        "localhost:8080",
        "localhost/123@sha256:\(String(repeating: "a", count: 200))",
        "https://github.com/apple/containerization",
        "",
        "-testString",
        "-testString/image",
        "-testString.com/image/release",
        "foo///bar",
        "mostly.valid/image/but/Caps",
        "[abc12::4]",
        "[abc12::4]:abc12::4",
        "[2001:db8:3:4::192.0.2.33]:5000/debian",
        "1a3f5e7d9c1b3a5f7e9d1c3b5a7f9e1d3c5b7a9f1e3d5d7c9b1a3f5e7d9c1b3a",
    ])
    func invalidReferenceParse(input: String) async throws {
        #expect(throws: ContainerizationError.self) {
            try Reference.parse(input)
        }
    }

    @Test(arguments: [
        ReferenceParseTestCase(input: "only_name", path: "only_name", tag: "latest"),
        ReferenceParseTestCase(input: "docker.io/alpine", domain: "docker.io", path: "library/alpine", tag: "latest"),
        ReferenceParseTestCase(input: "ghcr.io/myrepo/alpine", domain: "ghcr.io", path: "myrepo/alpine", tag: "latest"),
        ReferenceParseTestCase(input: "name@sha256:" + String(repeating: "1", count: 64), path: "name", digest: "sha256:" + String(repeating: "1", count: 64)),
        ReferenceParseTestCase(input: "registry-1.docker.io/testrepo/myname:v2", domain: "registry-1.docker.io", path: "testrepo/myname", tag: "v2"),
    ])
    func testNormalize(testCase: ReferenceParseTestCase) throws {
        let parsed = try Reference.parse(testCase.input)
        parsed.normalize()
        #expect(parsed.path == testCase.path)
        #expect(parsed.domain == testCase.domain)
        #expect(parsed.digest == testCase.digest)
        #expect(parsed.tag == testCase.tag)
    }
}
