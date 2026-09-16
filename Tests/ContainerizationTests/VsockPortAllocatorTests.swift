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

@testable import Containerization

struct VsockPortAllocatorTests {
    private let base: UInt32 = 0x1000_0000

    @Test func allocatesSequentiallyWhenNothingIsReleased() {
        let allocator = VsockPortAllocator(base: base)
        #expect(allocator.allocate() == base)
        #expect(allocator.allocate() == base + 1)
        #expect(allocator.allocate() == base + 2)
    }

    @Test func reusesTheLowestReleasedPort() {
        let allocator = VsockPortAllocator(base: base)
        let first = allocator.allocate()
        let second = allocator.allocate()
        _ = allocator.allocate()

        allocator.release(second)
        allocator.release(first)

        // Lowest-first keeps allocations packed at the bottom of the range, so
        // they stay inside a pre-bound window.
        #expect(allocator.allocate() == first)
        #expect(allocator.allocate() == second)
        #expect(allocator.allocate() == base + 3)
    }

    @Test func releaseIsIdempotentAndIgnoresUnknownPorts() {
        let allocator = VsockPortAllocator(base: base)
        let port = allocator.allocate()

        allocator.release(port)
        allocator.release(port)
        // Never handed out, and below the base: neither may enter the free set.
        allocator.release(base + 99)
        allocator.release(base - 1)

        #expect(allocator.allocate() == port)
        #expect(allocator.allocate() == base + 1)
    }

    /// The exec-ceiling regression, at the allocator level.
    ///
    /// A pre-bound vsock pool can only serve port numbers it bound up front,
    /// so a monotonically increasing number turned a pool of 16 into a budget
    /// of five processes for the VM's entire life — the fifth `exec` in a
    /// one-container pod asked for `base + 16` and failed. Sequential
    /// allocate/release cycles must stay inside the window instead.
    @Test func sequentialProcessesStayInsideAPreBoundWindow() {
        let allocator = VsockPortAllocator(base: base)
        let poolSize: UInt32 = 16
        let window = base..<(base + poolSize)

        // The container init holds three ports for the whole run.
        let held = [allocator.allocate(), allocator.allocate(), allocator.allocate()]

        // Then 50 sequential execs, each taking and returning three.
        for _ in 0..<50 {
            let ports = [allocator.allocate(), allocator.allocate(), allocator.allocate()]
            for port in ports {
                #expect(window.contains(port), "port \(port) fell outside the pre-bound window")
            }
            for port in ports {
                allocator.release(port)
            }
        }

        for port in held {
            #expect(window.contains(port))
        }
        // Exactly the three still-held ports are outstanding: the next
        // allocation is fresh rather than a recycled one.
        #expect(allocator.allocate() == base + 3)
    }

    @Test func concurrentAllocationsNeverCollide() async {
        let allocator = VsockPortAllocator(base: base)
        let count = 200

        let ports = await withTaskGroup(of: UInt32.self, returning: [UInt32].self) { group in
            for _ in 0..<count {
                group.addTask { allocator.allocate() }
            }
            var seen: [UInt32] = []
            for await port in group {
                seen.append(port)
            }
            return seen
        }

        #expect(ports.count == count)
        #expect(Set(ports).count == count, "a port was handed out twice")
    }
}
