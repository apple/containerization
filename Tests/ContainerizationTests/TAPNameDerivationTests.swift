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

#if os(Linux)
import Testing

@testable import Containerization

@Suite("TAP name derivation")
struct TAPNameDerivationTests {
    @Test("name is deterministic for a given id")
    func deterministic() {
        let a = LinuxBridgedNetwork.derivedTAPName(forID: "container-abc")
        let b = LinuxBridgedNetwork.derivedTAPName(forID: "container-abc")
        #expect(a == b)
    }

    @Test("different ids produce different names")
    func differentIds() {
        let a = LinuxBridgedNetwork.derivedTAPName(forID: "alpha")
        let b = LinuxBridgedNetwork.derivedTAPName(forID: "beta")
        #expect(a != b)
    }

    @Test("name fits within IFNAMSIZ - 1 (15 chars)")
    func ifnamsizFit() {
        for id in ["a", "short", "a-much-longer-container-id-that-exceeds-typical-bounds"] {
            let n = LinuxBridgedNetwork.derivedTAPName(forID: id)
            #expect(n.count <= 15, "name '\(n)' exceeds IFNAMSIZ-1")
        }
    }

    @Test("name uses czt- prefix")
    func prefix() {
        let n = LinuxBridgedNetwork.derivedTAPName(forID: "anything")
        #expect(n.hasPrefix("czt-"))
    }

    @Test("hex suffix is 10 chars")
    func suffixLength() {
        let n = LinuxBridgedNetwork.derivedTAPName(forID: "anything")
        // "czt-" is 4 chars; total 14.
        #expect(n.count == 14)
    }
}
#endif
