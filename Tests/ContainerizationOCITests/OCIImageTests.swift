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

//

import Testing

@testable import ContainerizationOCI

struct OCITests {
    @Test func config() {
        let config = OCIImageConfig()
        let rootfs = OCIRootfs(type: "foo", diffIDs: ["diff1", "diff2"])
        let history = OCIHistory()

        let image = OCIImage(architecture: "arm64", os: "linux", config: config, rootfs: rootfs, history: [history])
        #expect(image.rootfs.type == "foo")
    }

    @Test func descriptor() {
        let platform = OCIPlatform(arch: "arm64", os: "linux")
        let descriptor = OCIDescriptor(mediaType: OCIMediaTypes.descriptor, digest: "123", size: 0, platform: platform)

        #expect(descriptor.platform?.architecture == "arm64")
        #expect(descriptor.platform?.os == "linux")
    }

    @Test func index() {
        var descriptors: [OCIDescriptor] = []
        for i in 0..<5 {
            let descriptor = OCIDescriptor(mediaType: OCIMediaTypes.descriptor, digest: "\(i)", size: Int64(i))
            descriptors.append(descriptor)
        }

        let index = OCIIndex(schemaVersion: 1, manifests: descriptors)
        #expect(index.manifests.count == 5)
    }

    @Test func manifests() {
        var descriptors: [OCIDescriptor] = []
        for i in 0..<5 {
            let descriptor = OCIDescriptor(mediaType: OCIMediaTypes.descriptor, digest: "\(i)", size: Int64(i))
            descriptors.append(descriptor)
        }

        let config = OCIDescriptor(mediaType: OCIMediaTypes.descriptor, digest: "123", size: 0)

        let manifest = OCIManifest(schemaVersion: 1, config: config, layers: descriptors)
        #expect(manifest.config.digest == "123")
        #expect(manifest.layers.count == 5)
    }
}
