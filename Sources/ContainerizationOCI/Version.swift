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

public struct RuntimeSpecVersion: Sendable {
    public let major, minor, patch: Int
    public let dev: String

    public static let current = RuntimeSpecVersion(
        major: 1,
        minor: 0,
        patch: 2,
        dev: "-dev"
    )

    public init(major: Int, minor: Int, patch: Int, dev: String) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.dev = dev
    }
}
