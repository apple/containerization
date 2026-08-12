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

import ContainerizationOS
import Foundation

/// Works out how much memory a virtual machine should be asked to hold, from
/// what its guest is actually using.
///
/// The decision is made on the host because Virtualization's balloon takes a
/// target size and nothing else: the guest cannot hand pages back of its own
/// accord, so something outside has to look at what it is using and ask for the
/// rest. Cloud Hypervisor needs none of this, its balloon reporting the pages
/// the guest frees so the host reclaims them with no size to choose, which is
/// why the backend turns that on instead.
///
/// Kata answers the same question from inside the guest, its mem-agent using
/// MgLRU to reclaim cold pages per cgroup and free page reporting to give them
/// back. This is the host-side equivalent for a backend that offers only a
/// target.
/// https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-memory-agent.md
///
/// Reclaiming too far is the failure to avoid, because the guest then has to
/// fetch back pages it was still using. `workingsetRefaultAnon` counts exactly
/// that, so a rise in it since the last look is treated as evidence the last
/// target was too tight, and the policy gives the memory back and waits.
public struct MemoryReclaimPolicy: Sendable {
    /// Room left above what the guest is using, so ordinary allocation does not
    /// immediately have to wait for the balloon to deflate.
    public var headroom: UInt64
    /// The least a machine will be asked to hold, whatever its guest reports.
    public var floor: UInt64
    /// How much of the machine to give back at once after refaults are seen.
    public var backoff: UInt64

    public init(
        headroom: UInt64 = 256.mib(),
        floor: UInt64 = 256.mib(),
        backoff: UInt64 = 256.mib()
    ) {
        self.headroom = headroom
        self.floor = floor
        self.backoff = backoff
    }

    /// The size to ask for next.
    ///
    /// - Parameters:
    ///   - anon: Anonymous memory the guest holds. Page cache is left out
    ///     because the guest can drop it without help.
    ///   - refaulted: Whether anonymous pages have been fetched back since the
    ///     last look, meaning the previous target was too tight.
    ///   - current: What the machine is holding now.
    ///   - ceiling: The size the machine was created with, which it cannot
    ///     exceed.
    public func nextTarget(
        anon: UInt64,
        refaulted: Bool,
        current: UInt64,
        ceiling: UInt64
    ) -> UInt64 {
        if refaulted {
            return min(ceiling, current + backoff)
        }
        let wanted = anon + headroom
        return min(ceiling, max(floor, wanted))
    }
}

/// Tracks a machine across looks so refaults can be compared against the
/// previous reading rather than treated as an absolute.
public actor MemoryReclaimer {
    /// What the reclaimer has done so far: how often it looked at the guest,
    /// how often it asked the machine for a new size, how often a look or an
    /// ask failed, and the size it last asked for.
    public struct Report: Sendable {
        public var looks: Int = 0
        public var applies: Int = 0
        public var failures: Int = 0
        public var target: UInt64?
        public var lastAnon: UInt64 = 0
        public var maxAnon: UInt64 = 0
        public var lastRefaultAnon: UInt64 = 0
    }

    private let policy: MemoryReclaimPolicy
    private let ceiling: UInt64
    private var lastRefaultAnon: UInt64?
    private var current: UInt64
    private var report = Report()

    public init(policy: MemoryReclaimPolicy = .init(), ceiling: UInt64) {
        self.policy = policy
        self.ceiling = ceiling
        self.current = ceiling
    }

    public func currentReport() -> Report {
        report
    }

    /// Fold in one reading and return the size to ask for, or nil when it has
    /// not changed enough to be worth asking.
    public func step(memory: ContainerStatistics.MemoryStatistics) -> UInt64? {
        step(anon: memory.anon, refaultAnon: memory.workingsetRefaultAnon)
    }

    /// Fold in one reading and return the size to ask for, or nil when it has
    /// not changed enough to be worth asking.
    /// - Parameters:
    ///   - anon: Anonymous memory the guest holds.
    ///   - refaultAnon: The guest's running count of anonymous pages fetched
    ///     back after reclaim.
    public func step(anon: UInt64, refaultAnon: UInt64) -> UInt64? {
        let refaulted =
            lastRefaultAnon.map { refaultAnon > $0 } ?? false
        lastRefaultAnon = refaultAnon

        let target = policy.nextTarget(
            anon: anon,
            refaulted: refaulted,
            current: current,
            ceiling: ceiling
        )
        // Virtualization rounds the target to a megabyte, so anything smaller
        // than that is not a change at all.
        guard target != current, target.absoluteDistance(to: current) >= 1.mib() else {
            return nil
        }
        current = target
        return target
    }
}

extension MemoryReclaimer {
    /// Look at the guest on a cadence until cancelled: sample what it holds,
    /// fold the reading in, and apply the size that comes out.
    ///
    /// A sample or apply that fails leaves the machine as it was; the next
    /// look starts fresh.
    public func run(
        interval: Duration,
        sample: @Sendable () async throws -> (anon: UInt64, refaultAnon: UInt64),
        apply: @Sendable (UInt64) async throws -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
                let (anon, refaultAnon) = try await sample()
                report.looks += 1
                report.lastAnon = anon
                report.maxAnon = max(report.maxAnon, anon)
                report.lastRefaultAnon = refaultAnon
                if let target = step(anon: anon, refaultAnon: refaultAnon) {
                    report.target = target
                    try await apply(target)
                    report.applies += 1
                }
            } catch is CancellationError {
                return
            } catch {
                report.failures += 1
                continue
            }
        }
    }
}

extension UInt64 {
    fileprivate func absoluteDistance(to other: UInt64) -> UInt64 {
        self > other ? self - other : other - self
    }
}
