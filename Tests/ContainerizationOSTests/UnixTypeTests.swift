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

@testable import ContainerizationOS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("UnixType path length tests")
struct UnixTypeTests {
    // The real capacity of sockaddr_un.sun_path on this platform (104 on
    // macOS, 108 on Linux) — derived the same way UnixType.init(path:)
    // derives its own `lengthLimit`, so this test tracks the real field
    // size on every platform instead of hardcoding a platform-specific number.
    private var sunPathCapacity: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    @Test("path that leaves room for the NUL terminator is accepted")
    func acceptsPathWithinCapacity() throws {
        let path = String(repeating: "a", count: sunPathCapacity - 1)
        _ = try UnixType(path: path)
    }

    @Test("path that exactly fills sun_path with no room for a terminator is rejected")
    func rejectsPathFillingCapacity() {
        let path = String(repeating: "a", count: sunPathCapacity)
        #expect(throws: UnixType.Error.self) {
            _ = try UnixType(path: path)
        }
    }

    @Test("path far longer than sun_path's capacity is rejected")
    func rejectsPathExceedingCapacity() {
        let path = String(repeating: "a", count: sunPathCapacity + 148)
        #expect(throws: UnixType.Error.self) {
            _ = try UnixType(path: path)
        }
    }
}
