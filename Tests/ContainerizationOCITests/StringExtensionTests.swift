//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

struct StringExtensionTests {

    // MARK: - trimmingDigestPrefix Tests

    @Test func trimmingDigestPrefixRemovesSha256Prefix() throws {
        let digestWithPrefix = "sha256:abc123def456"
        let result = digestWithPrefix.trimmingDigestPrefix

        #expect(result == "abc123def456")
    }

    @Test func trimmingDigestPrefixRemovesCustomPrefix() throws {
        let digestWithPrefix = "md5:xyz789"
        let result = digestWithPrefix.trimmingDigestPrefix

        #expect(result == "xyz789")
    }

    @Test func trimmingDigestPrefixHandlesNoPrefix() throws {
        let digestWithoutPrefix = "abc123def456"
        let result = digestWithoutPrefix.trimmingDigestPrefix

        #expect(result == "abc123def456")
    }

    @Test func trimmingDigestPrefixHandlesEmptyString() throws {
        let emptyString = ""
        let result = emptyString.trimmingDigestPrefix

        #expect(result == "")
    }

    @Test func trimmingDigestPrefixHandlesMultipleColons() throws {
        let multipleColons = "sha256:abc:def:123"
        let result = multipleColons.trimmingDigestPrefix

        // Only works when split results in exactly 2 components
        // Multiple colons means more than 2 components, so returns original
        #expect(result == "sha256:abc:def:123")
    }

    @Test func trimmingDigestPrefixHandlesColonOnly() throws {
        let colonOnly = ":"
        let result = colonOnly.trimmingDigestPrefix

        // Only 1 component after split, so returns original
        #expect(result == ":")
    }

    @Test func trimmingDigestPrefixHandlesColonAtEnd() throws {
        let colonAtEnd = "sha256:"
        let result = colonAtEnd.trimmingDigestPrefix

        // Only 1 component after split (empty second part), so returns original
        #expect(result == "sha256:")
    }

    @Test func trimmingDigestPrefixHandlesColonAtStart() throws {
        let colonAtStart = ":abc123"
        let result = colonAtStart.trimmingDigestPrefix

        // Only 1 component after split (empty first part), so returns original
        #expect(result == ":abc123")
    }

    @Test func trimmingDigestPrefixPreservesRealWorldDigests() throws {
        let realDigest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let result = realDigest.trimmingDigestPrefix

        #expect(result == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func trimmingDigestPrefixHandlesShortHash() throws {
        let shortHash = "sha256:abc"
        let result = shortHash.trimmingDigestPrefix

        #expect(result == "abc")
    }
}
