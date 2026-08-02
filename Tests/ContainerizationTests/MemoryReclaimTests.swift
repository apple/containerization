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

import ContainerizationExtras
import Foundation
import Testing

@testable import Containerization

struct MemoryReclaimTests {
    private let policy = MemoryReclaimPolicy(
        headroom: 256.mib(),
        floor: 256.mib(),
        backoff: 256.mib()
    )

    @Test func targetFollowsWhatTheGuestHolds() {
        let target = policy.nextTarget(
            anon: 512.mib(),
            refaulted: false,
            current: 4096.mib(),
            ceiling: 4096.mib()
        )
        #expect(target == 768.mib())
    }

    @Test func targetNeverFallsBelowTheFloor() {
        let target = policy.nextTarget(
            anon: 0,
            refaulted: false,
            current: 4096.mib(),
            ceiling: 4096.mib()
        )
        #expect(target == 256.mib())
    }

    @Test func targetNeverExceedsTheSizeTheMachineWasCreatedWith() {
        let target = policy.nextTarget(
            anon: 8192.mib(),
            refaulted: false,
            current: 1024.mib(),
            ceiling: 1024.mib()
        )
        #expect(target == 1024.mib())
    }

    /// Refaults mean the guest had to fetch back pages it was still using, so
    /// the previous target was too tight and memory goes back rather than the
    /// reading being trusted.
    @Test func refaultsGiveMemoryBackInsteadOfShrinkingFurther() {
        let target = policy.nextTarget(
            anon: 128.mib(),
            refaulted: true,
            current: 512.mib(),
            ceiling: 4096.mib()
        )
        #expect(target == 768.mib())
    }

    @Test func givingBackStopsAtTheCeiling() {
        let target = policy.nextTarget(
            anon: 128.mib(),
            refaulted: true,
            current: 4000.mib(),
            ceiling: 4096.mib()
        )
        #expect(target == 4096.mib())
    }

    @Test func firstReadingIsNotTreatedAsARefault() async {
        let reclaimer = MemoryReclaimer(policy: policy, ceiling: 4096.mib())
        let target = await reclaimer.step(memory: Self.memory(anon: 512.mib(), refaults: 900))
        // Without a previous reading there is nothing to compare against, so
        // the count is recorded and the guest's usage is followed.
        #expect(target == 768.mib())
    }

    @Test func aRepeatedReadingAsksForNothing() async {
        let reclaimer = MemoryReclaimer(policy: policy, ceiling: 4096.mib())
        _ = await reclaimer.step(memory: Self.memory(anon: 512.mib(), refaults: 0))
        let again = await reclaimer.step(memory: Self.memory(anon: 512.mib(), refaults: 0))
        #expect(again == nil)
    }

    @Test func risingRefaultsReverseTheLastReclaim() async {
        let reclaimer = MemoryReclaimer(policy: policy, ceiling: 4096.mib())
        let first = await reclaimer.step(memory: Self.memory(anon: 512.mib(), refaults: 10))
        #expect(first == 768.mib())
        let second = await reclaimer.step(memory: Self.memory(anon: 512.mib(), refaults: 99))
        #expect(second == 1024.mib())
    }

    private static func memory(anon: UInt64, refaults: UInt64) -> ContainerStatistics.MemoryStatistics {
        .init(
            usageBytes: anon,
            limitBytes: 0,
            swapUsageBytes: 0,
            swapLimitBytes: 0,
            cacheBytes: 0,
            kernelStackBytes: 0,
            slabBytes: 0,
            pageFaults: 0,
            majorPageFaults: 0,
            inactiveFile: 0,
            anon: anon,
            workingsetRefaultAnon: refaults
        )
    }
}
