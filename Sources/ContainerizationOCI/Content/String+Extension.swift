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

extension String {
    /// Removes any prefix (sha256:) from a digest string.
    ///
    /// - Warning: This performs **no validation** despite its name. For
    ///   `sha256:../../etc/hosts` it returns `../../etc/hosts`, and for a string
    ///   with no colon, or more than one, it returns the input unchanged. It must
    ///   never be used to build a filesystem path from a digest that came from a
    ///   registry or an on-disk image layout — use ``validatedDigestEncoding()``,
    ///   which rejects anything that is not a well formed digest, or
    ///   ``ParsedDigest/path(in:)`` to resolve one to a path.
    @available(*, deprecated, message: "Does not validate. Use validatedDigestEncoding() for paths, or SHA256.Digest.encoded for a computed hash.")
    public var trimmingDigestPrefix: String {
        let split = self.split(separator: ":")
        if split.count == 2 {
            return String(split[1])
        }
        return self
    }
}
