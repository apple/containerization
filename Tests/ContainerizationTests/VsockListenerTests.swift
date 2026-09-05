//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import Foundation
import Testing

@testable import Containerization

struct VsockListenerTests {
    @Test func connectionOwnerOutlivesTheDescriptorHandoff() throws {
        var handle: FileHandle? = FileHandle(forReadingAtPath: "/dev/null")
        try #require(handle != nil)

        var owner: ConnectionOwner? = ConnectionOwner()
        weak let weakOwner = owner
        retainConnectionOwner(owner!, for: handle!)
        owner = nil

        #expect(weakOwner != nil)

        try handle?.close()
        handle = nil

        #expect(weakOwner == nil)
    }
}

private final class ConnectionOwner {}
#endif
