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

@testable import ContainerizationEXT4

struct TestFileTimestamps {
    @Test func testFileTimestampsInit() {
        let now = Date()
        let access = now.addingTimeInterval(-3600)  // 1 hour ago
        let modification = now.addingTimeInterval(-1800)  // 30 minutes ago
        let creation = now.addingTimeInterval(-7200)  // 2 hours ago

        let timestamps = FileTimestamps(access: access, modification: modification, creation: creation)

        #expect(timestamps.access == access)
        #expect(timestamps.modification == modification)
        #expect(timestamps.creation == creation)
        #expect(timestamps.now.timeIntervalSince1970 >= now.timeIntervalSince1970)
    }

    @Test func testFileTimestampsDefaultInit() {
        let timestamps = FileTimestamps()
        let now = Date()

        #expect(timestamps.access.timeIntervalSince1970 >= now.timeIntervalSince1970 - 1)
        #expect(timestamps.modification.timeIntervalSince1970 >= now.timeIntervalSince1970 - 1)
        #expect(timestamps.creation.timeIntervalSince1970 >= now.timeIntervalSince1970 - 1)
        #expect(timestamps.now.timeIntervalSince1970 >= now.timeIntervalSince1970 - 1)
    }

    @Test func testFileTimestampsWithNilValues() {
        let timestamps = FileTimestamps(access: nil, modification: nil, creation: nil)
        let now = Date()

        #expect(timestamps.access.timeIntervalSince1970 >= now.timeIntervalSince1970 - 1)
        #expect(timestamps.modification.timeIntervalSince1970 >= now.timeIntervalSince1970 - 1)
        #expect(timestamps.creation.timeIntervalSince1970 >= now.timeIntervalSince1970 - 1)
    }

    @Test func testFileTimestampsLoHiAccessors() {
        let timestamp = Date(timeIntervalSince1970: 1234567890.123456)
        let timestamps = FileTimestamps(access: timestamp, modification: timestamp, creation: timestamp)

        let fsTime = timestamp.fs()

        #expect(timestamps.accessLo == fsTime.lo)
        #expect(timestamps.accessHi == fsTime.hi)
        #expect(timestamps.modificationLo == fsTime.lo)
        #expect(timestamps.modificationHi == fsTime.hi)
        #expect(timestamps.creationLo == fsTime.lo)
        #expect(timestamps.creationHi == fsTime.hi)

        let nowFsTime = timestamps.now.fs()
        #expect(timestamps.nowLo == nowFsTime.lo)
        #expect(timestamps.nowHi == nowFsTime.hi)
    }

    @Test func testFileTimestampsPartialInit() {
        let access = Date(timeIntervalSince1970: 1000)
        let modification = Date(timeIntervalSince1970: 2000)

        let timestamps = FileTimestamps(access: access, modification: modification, creation: nil)

        #expect(timestamps.access == access)
        #expect(timestamps.modification == modification)
        #expect(timestamps.creation.timeIntervalSince1970 >= timestamps.now.timeIntervalSince1970 - 1)
    }
}
