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

import Crypto
import Foundation

extension SHA256.Digest {
    /// Returns the digest as a string.
    public var digestString: String {
        let parts = self.description.split(separator: ": ")
        return "sha256:\(parts[1])"
    }

    /// Returns the digest without a 'sha256:' prefix.
    public var encoded: String {
        let parts = self.description.split(separator: ": ")
        return String(parts[1])
    }
}
