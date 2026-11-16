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

/// A page of `GET /v2/<name>/tags/list` as the distribution spec defines it.
struct RegistryClientTagsTests {
    private func entries(_ json: String) throws -> [String] {
        try JSONDecoder().decode(RegistryClient.TagsResponse.self, from: Data(json.utf8)).entries
    }

    @Test func decodesTags() throws {
        #expect(try entries(#"{"name":"org/app","tags":["1.0","latest"]}"#) == ["1.0", "latest"])
    }

    /// The spec allows `tags` to be `null` for a repository without tags.
    @Test func treatsNullTagsAsEmpty() throws {
        #expect(try entries(#"{"name":"org/app","tags":null}"#).isEmpty)
    }

    @Test func treatsMissingTagsAsEmpty() throws {
        #expect(try entries(#"{"name":"org/app"}"#).isEmpty)
    }
}
