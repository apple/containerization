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

import ContainerizationOCI
import Foundation
import Testing

@testable import Containerization

struct ImageTests {

    @Test func imageDescriptionComputedProperties() {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:abc123def456",
            size: 1024
        )
        let description = Image.Description(reference: "myapp:latest", descriptor: descriptor)

        #expect(description.digest == "sha256:abc123def456")
        #expect(description.mediaType == "application/vnd.oci.image.manifest.v1+json")
        #expect(description.reference == "myapp:latest")
    }
}
