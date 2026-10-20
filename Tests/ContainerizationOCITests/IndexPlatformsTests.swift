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

struct IndexPlatformsTests {
    private static let digest = "sha256:" + String(repeating: "0", count: 64)

    private static func manifest(_ platform: Platform?, annotations: [String: String]? = nil) -> Descriptor {
        Descriptor(mediaType: MediaTypes.imageManifest, digest: digest, size: 1, annotations: annotations, platform: platform)
    }

    @Test func dropsUnknownAndAttestation() {
        let index = Index(manifests: [
            Self.manifest(Platform(arch: "arm64", os: "linux", variant: "v8")),
            Self.manifest(Platform(arch: "unknown", os: "unknown"), annotations: ["vnd.docker.reference.type": "attestation-manifest"]),
            Self.manifest(Platform(arch: "unknown", os: "unknown")),
            Self.manifest(Platform(arch: "arm64", os: "linux"), annotations: ["vnd.docker.reference.type": "attestation-manifest"]),
            Self.manifest(nil),
        ])

        #expect(index.runnablePlatforms == [Platform(arch: "arm64", os: "linux", variant: "v8")])
    }

    @Test func keepsNonLinux() {
        let index = Index(manifests: [Self.manifest(Platform(arch: "amd64", os: "windows"))])

        #expect(index.runnablePlatforms == [Platform(arch: "amd64", os: "windows")])
    }
}
