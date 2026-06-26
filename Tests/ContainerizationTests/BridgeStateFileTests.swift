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

import Foundation
import Testing

@testable import Containerization

@Suite("Bridge state file")
struct BridgeStateFileTests {
    @Test("round-trip JSON encode/decode (NAT enabled)")
    func roundTripNAT() throws {
        let s = BridgeState(natEnabled: true, prevIpForward: "0", egressInterface: "eth0")
        let data = try s.encode()
        let s2 = try BridgeState.decode(data)
        #expect(s2.natEnabled == true)
        #expect(s2.prevIpForward == "0")
        #expect(s2.egressInterface == "eth0")
    }

    @Test("round-trip JSON encode/decode (NAT disabled)")
    func roundTripNoNAT() throws {
        let s = BridgeState(natEnabled: false)
        let data = try s.encode()
        let s2 = try BridgeState.decode(data)
        #expect(s2.natEnabled == false)
        #expect(s2.prevIpForward == nil)
        #expect(s2.egressInterface == nil)
    }

    @Test("legacy state file without natEnabled defaults to true")
    func legacyDefaultsToNATEnabled() throws {
        // Pre-flag JSON shape, written by an older version of BridgeManager.
        let legacy = #"{"prevIpForward":"0","egressInterface":"eth0"}"#
        let s = try BridgeState.decode(Data(legacy.utf8))
        #expect(s.natEnabled == true)
        #expect(s.prevIpForward == "0")
        #expect(s.egressInterface == "eth0")
    }

    @Test("decode rejects malformed input")
    func malformed() {
        #expect(throws: (any Error).self) {
            _ = try BridgeState.decode(Data("not json".utf8))
        }
    }
}
