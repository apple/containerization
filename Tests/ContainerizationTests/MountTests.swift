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

import Foundation
import Testing

@testable import Containerization

struct MountTests {

    @Test func mountShareCreatesVirtiofsMount() {
        let mount = Mount.share(
            source: "/host/shared",
            destination: "/guest/shared",
            options: ["rw", "noatime"],
            runtimeOptions: ["tag=shared"]
        )

        #expect(mount.type == "virtiofs")
        #expect(mount.source == "/host/shared")
        #expect(mount.destination == "/guest/shared")
        #expect(mount.options == ["rw", "noatime"])

        if case .virtiofs(let opts) = mount.runtimeOptions {
            #expect(opts == ["tag=shared"])
        } else {
            #expect(Bool(false), "Expected virtiofs runtime options")
        }
    }
}
