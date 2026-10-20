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

extension Index {
    private static let referenceTypeKey = "vnd.docker.reference.type"
    private static let attestationType = "attestation-manifest"
    private static let unknown = "unknown"

    /// Platforms of the image manifests, excluding attestations and `unknown/unknown` entries.
    public var runnablePlatforms: [Platform] {
        manifests
            .filter { $0.annotations?[Self.referenceTypeKey] != Self.attestationType }
            .compactMap(\.platform)
            .filter { !($0.os == Self.unknown && $0.architecture == Self.unknown) }
    }
}
