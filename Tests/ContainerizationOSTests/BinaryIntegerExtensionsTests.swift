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

import Foundation
import Testing

@testable import ContainerizationOS

struct BinaryIntegerExtensionsTests {

    @Test func binaryIntegerMemoryConversions() {
        #expect(1.mib() == 1_048_576)  // 1 * 1024 * 1024
        #expect(2.gib() == 2_147_483_648)  // 2 * 1024 * 1024 * 1024
        #expect(4.kib() == 4_096)  // 4 * 1024

        // Test different integer types
        #expect(UInt32(512).mib() == 536_870_912)
        #expect(Int64(1).gib() == 1_073_741_824)
    }

    @Test func binaryIntegerLargeMemoryConversions() {
        #expect(1.tib() == 1_099_511_627_776)  // 1 * 1024^4
        #expect(1.pib() == 1_125_899_906_842_624)  // 1 * 1024^5
    }
}
