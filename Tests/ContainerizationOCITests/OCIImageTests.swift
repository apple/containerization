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

//

import Testing

@testable import ContainerizationOCI

struct OCITests {
    @Test func config() {
        let config = ContainerizationOCI.ImageConfig()
        let rootfs = ContainerizationOCI.Rootfs(type: "foo", diffIDs: ["diff1", "diff2"])
        let history = ContainerizationOCI.History()

        let image = ContainerizationOCI.Image(architecture: "arm64", os: "linux", config: config, rootfs: rootfs, history: [history])
        #expect(image.rootfs.type == "foo")
    }

    @Test func descriptor() {
        let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux")
        let descriptor = ContainerizationOCI.Descriptor(mediaType: MediaTypes.descriptor, digest: "123", size: 0, platform: platform)

        #expect(descriptor.platform?.architecture == "arm64")
        #expect(descriptor.platform?.os == "linux")
    }

    @Test func index() {
        var descriptors: [ContainerizationOCI.Descriptor] = []
        for i in 0..<5 {
            let descriptor = ContainerizationOCI.Descriptor(mediaType: MediaTypes.descriptor, digest: "\(i)", size: Int64(i))
            descriptors.append(descriptor)
        }

        let index = ContainerizationOCI.Index(schemaVersion: 1, manifests: descriptors)
        #expect(index.manifests.count == 5)
    }

    @Test func manifests() {
        var descriptors: [ContainerizationOCI.Descriptor] = []
        for i in 0..<5 {
            let descriptor = ContainerizationOCI.Descriptor(mediaType: MediaTypes.descriptor, digest: "\(i)", size: Int64(i))
            descriptors.append(descriptor)
        }

        let config = ContainerizationOCI.Descriptor(mediaType: MediaTypes.descriptor, digest: "123", size: 0)

        let manifest = ContainerizationOCI.Manifest(schemaVersion: 1, config: config, layers: descriptors)
        #expect(manifest.config.digest == "123")
        #expect(manifest.layers.count == 5)
    }
}
