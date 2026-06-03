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

#if os(macOS)

import ContainerizationError
import ContainerizationExtras
import Testing

@testable import Containerization

struct AllocatorTests {

    @Test func allocateDualStackReturnsDistinctPairs() throws {
        guard #available(macOS 26, *) else { return }
        var alloc = try VmnetNetwork.Allocator(
            cidrV4: try CIDRv4("192.168.64.0/24"),
            cidrV6: try CIDRv6("fd00::/64"))

        let (a4, a6) = try alloc.allocate("a")
        let (b4, b6) = try alloc.allocate("b")

        #expect(a4 != b4)
        #expect(a6 != nil && b6 != nil)
        #expect(a6 != b6)

        // The v4 allocator starts at lower + 2 (skipping network base + gateway),
        // so the first two allocations are .2 and .3.
        #expect(a4 == (try CIDRv4("192.168.64.2/24")))
        #expect(b4 == (try CIDRv4("192.168.64.3/24")))
    }

    @Test func allocateWithNoV6PrefixReturnsNilV6() throws {
        guard #available(macOS 26, *) else { return }
        var alloc = try VmnetNetwork.Allocator(
            cidrV4: try CIDRv4("192.168.64.0/24"),
            cidrV6: nil)

        let (_, a6) = try alloc.allocate("a")
        #expect(a6 == nil)
    }

    @Test func duplicateIdThrows() throws {
        guard #available(macOS 26, *) else { return }
        var alloc = try VmnetNetwork.Allocator(
            cidrV4: try CIDRv4("192.168.64.0/24"),
            cidrV6: try CIDRv6("fd00::/64"))
        _ = try alloc.allocate("a")
        #expect(throws: ContainerizationError.self) {
            _ = try alloc.allocate("a")
        }
    }

    @Test func releaseAllowsIdReuse() throws {
        guard #available(macOS 26, *) else { return }
        var alloc = try VmnetNetwork.Allocator(
            cidrV4: try CIDRv4("192.168.64.0/24"),
            cidrV6: try CIDRv6("fd00::/64"))

        _ = try alloc.allocate("a")
        // Re-allocating 'a' would throw .exists if release didn't clear it.
        try alloc.release("a")
        _ = try alloc.allocate("a")
    }

    @Test func releaseUnknownIdIsNoOp() throws {
        guard #available(macOS 26, *) else { return }
        var alloc = try VmnetNetwork.Allocator(
            cidrV4: try CIDRv4("192.168.64.0/24"),
            cidrV6: try CIDRv6("fd00::/64"))
        try alloc.release("never-allocated")
    }

    @Test func v6HostPortionUsesOrdinalIndex() throws {
        guard #available(macOS 26, *) else {
            return
        }
        var alloc = try VmnetNetwork.Allocator(
            cidrV4: try CIDRv4("192.168.64.0/24"),
            cidrV6: try CIDRv6("fd00::/64"))

        let (_, a6) = try alloc.allocate("a")
        let (_, b6) = try alloc.allocate("b")

        let aHost = a6!.address.value & a6!.prefix.suffixMask128
        let bHost = b6!.address.value & b6!.prefix.suffixMask128
        #expect(aHost == 2)
        #expect(bHost == 3)
    }

    @Test func cidrV6Gateway() throws {
        // The network gateway is the lowest address + 1.
        #expect((try CIDRv6("fd00::/64")).gateway == (try IPv6Address("fd00::1")))
        #expect((try CIDRv6("fd00:abcd:1234::/48")).gateway == (try IPv6Address("fd00:abcd:1234::1")))
    }

    @available(macOS 26, *)
    private actor SerialAllocator {
        private var inner: VmnetNetwork.Allocator
        init(cidrV4: CIDRv4, cidrV6: CIDRv6?) throws {
            self.inner = try VmnetNetwork.Allocator(cidrV4: cidrV4, cidrV6: cidrV6)
        }
        func allocate(_ id: String) throws -> (CIDRv4, CIDRv6?) {
            try inner.allocate(id)
        }
        func release(_ id: String) throws {
            try inner.release(id)
        }
    }

    @Test func returnsUniqueAddressesUnderConcurrentLoad() async throws {
        guard #available(macOS 26, *) else { return }
        // /16 host space is much larger than `count`, so we won't hit the
        // pool ceiling — we're testing for collisions/state corruption.
        let alloc = try SerialAllocator(
            cidrV4: try CIDRv4("10.0.0.0/16"),
            cidrV6: try CIDRv6("fd00::/64"))

        let count = 1000
        let pairs = try await withThrowingTaskGroup(of: (CIDRv4, CIDRv6?).self) { group in
            for i in 0..<count {
                group.addTask {
                    try await alloc.allocate("id-\(i)")
                }
            }
            var collected: [(CIDRv4, CIDRv6?)] = []
            for try await pair in group {
                collected.append(pair)
            }
            return collected
        }

        #expect(pairs.count == count)
        let v4s = Set(pairs.map { $0.0 })
        let v6s = Set(pairs.compactMap { $0.1 })
        #expect(v4s.count == count)
        #expect(v6s.count == count)
    }

    @Test func throwsWhenPoolExhausted() throws {
        guard #available(macOS 26, *) else { return }
        // /29 has 8 host addresses; allocator capacity is `upper - lower - 3 = 4` slots.
        var alloc = try VmnetNetwork.Allocator(
            cidrV4: try CIDRv4("10.0.0.0/29"),
            cidrV6: try CIDRv6("fd00::/64"))

        for i in 0..<4 {
            _ = try alloc.allocate("id-\(i)")
        }
        // The 5th allocation must fail since the v4 pool is drained.
        #expect(throws: (any Error).self) {
            _ = try alloc.allocate("id-overflow")
        }
    }
}

#endif
