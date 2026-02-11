//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

//

import ContainerizationExtras
import Testing

@testable import ContainerizationExtras

final class TestAddressAllocators {
    @Test
    func testIPv4AddressAllocatorZeroSize() throws {
        _ = try IPv4Address.allocator(lower: 0xffff_ffff, size: 1)
        do {
            _ = try IPv4Address.allocator(lower: 0xffff_ffff, size: 0)
            #expect(Bool(false), "Expected AllocatorError.rangeExceeded to be thrown")
        } catch {
            #expect(error as? AllocatorError == .rangeExceeded, "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testIPv4AddressAllocatorOverflow() throws {
        _ = try IPv4Address.allocator(lower: 0xffff_ff00, size: 256)
        do {
            _ = try IPv4Address.allocator(lower: 0xffff_ff00, size: 257)
            #expect(Bool(false), "Expected AllocatorError.rangeExceeded to be thrown")
        } catch {
            #expect(error as? AllocatorError == .rangeExceeded, "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testUInt16AllocatorOverflow() throws {
        _ = try UInt16.allocator(lower: 0xfff0, size: 16)
        do {
            _ = try UInt16.allocator(lower: 0xfff0, size: 17)
            #expect(Bool(false), "Expected AllocatorError.rangeExceeded to be thrown")
        } catch {
            #expect(error as? AllocatorError == .rangeExceeded, "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testUInt32AllocatorOverflow() throws {
        _ = try UInt32.allocator(lower: 0xffff_fff0, size: 16)
        do {
            _ = try UInt32.allocator(lower: 0xffff_fff0, size: 17)
            #expect(Bool(false), "Expected AllocatorError.rangeExceeded to be thrown")
        } catch {
            #expect(error as? AllocatorError == .rangeExceeded, "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testFreeUnallocated() throws {
        let allocator = try IPv4Address.allocator(
            lower: 0xc0a8_4000, size: 256)
        do {
            _ = try allocator.release(IPv4Address("192.168.64.2"))
            #expect(Bool(false), "Expected AllocatorError.notAllocated to be thrown")
        } catch {
            #expect(error as? AllocatorError == .notAllocated("192.168.64.2"), "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testChoose() throws {
        let allocator = try IPv4Address.allocator(
            lower: 0xc0a8_4000, size: 2)
        try allocator.reserve(IPv4Address("192.168.64.1"))
        do {
            _ = try allocator.reserve(IPv4Address("192.168.64.1"))
            #expect(Bool(false), "Expected AllocatorError.alreadyAllocated to be thrown")
        } catch {
            #expect(error as? AllocatorError == .alreadyAllocated("192.168.64.1"), "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testipv4AddressAllocator() throws {
        var allocations = Set<UInt32>()
        let lower = try IPv4Address("192.168.64.1").value & Prefix(length: 24)!.prefixMask32
        let allocator = try IPv4Address.allocator(
            lower: lower, size: 3)
        allocations.insert(try allocator.allocate().value)
        allocations.insert(try allocator.allocate().value)
        allocations.insert(try allocator.allocate().value)
        do {
            _ = try allocator.allocate()
            #expect(Bool(false), "Expected AllocatorError.allocatorFull to be thrown")
        } catch {
            #expect(error as? AllocatorError == .allocatorFull, "Unexpected error thrown: \(error)")
        }

        let address = try IPv4Address("192.168.64.2")
        try allocator.release(address)

        let value = try allocator.allocate()
        #expect(value == address)
    }

    @Test
    func testHighestIPv4AddressAllocator() throws {
        var allocations = Set<UInt32>()
        let lower = try IPv4Address("255.255.255.255").value & Prefix(length: 32)!.prefixMask32
        let allocator = try IPv4Address.allocator(
            lower: lower, size: 1)
        allocations.insert(try allocator.allocate().value)
        do {
            _ = try allocator.allocate()
            #expect(Bool(false), "Expected AllocatorError.allocatorFull to be thrown")
        } catch {
            #expect(error as? AllocatorError == .allocatorFull, "Unexpected error thrown: \(error)")
        }

        let address = try IPv4Address("255.255.255.255")
        try allocator.release(address)
        let value = try allocator.allocate()
        #expect(value == address)
    }

    @Test
    func testLargestIPv4AddressAllocator() throws {
        // NOTE: This allocator should consume about 16MB
        _ = try IPv4Address.allocator(lower: 0, size: 1 << 32)
    }

    @Test
    func testUInt16PortAllocator() throws {
        var allocations = Set<UInt16>()
        let lower = UInt16(1024)
        let allocator = try UInt16.allocator(lower: lower, size: 3)
        allocations.insert(try allocator.allocate())
        allocations.insert(try allocator.allocate())
        allocations.insert(try allocator.allocate())
        do {
            _ = try allocator.allocate()
            #expect(Bool(false), "Expected AllocatorError.allocatorFull to be thrown")
        } catch {
            #expect(error as? AllocatorError == .allocatorFull, "Unexpected error thrown: \(error)")
        }

        let address = UInt16(1025)
        try allocator.release(address)
        let value = try allocator.allocate()
        #expect(value == address)
    }

    @Test
    func testUInt32PortAllocator() throws {
        var allocations = Set<UInt32>()
        let lower = UInt32(5000)
        let allocator = try UInt32.allocator(lower: lower, size: 3)
        allocations.insert(try allocator.allocate())
        allocations.insert(try allocator.allocate())
        allocations.insert(try allocator.allocate())
        do {
            _ = try allocator.allocate()
            #expect(Bool(false), "Expected AllocatorError.allocatorFull to be thrown")
        } catch {
            #expect(error as? AllocatorError == .allocatorFull, "Unexpected error thrown: \(error)")
        }

        let address = UInt32(5001)
        try allocator.release(address)
        let value = try allocator.allocate()
        #expect(value == address)
    }

    @Test
    func testRotatingUInt32PortAllocator() throws {
        var allocations = Set<UInt32>()
        let lower = UInt32(5000)
        let allocator = try UInt32.rotatingAllocator(lower: lower, size: 3)
        allocations.insert(try allocator.allocate())
        allocations.insert(try allocator.allocate())
        allocations.insert(try allocator.allocate())
        do {
            _ = try allocator.allocate()
            #expect(Bool(false), "Expected AllocatorError.allocatorFull to be thrown")
        } catch {
            #expect(error as? AllocatorError == .allocatorFull, "Unexpected error thrown: \(error)")
        }

        let address = UInt32(5001)
        try allocator.release(address)
        let value = try allocator.allocate()
        #expect(value == address)
    }

    @Test
    func testRotatingFIFOUInt32PortAllocator() throws {
        let lower = UInt32(5000)
        let allocator = try UInt32.rotatingAllocator(lower: lower, size: 3)
        let first = try allocator.allocate()
        #expect(first == 5000)
        let second = try allocator.allocate()
        #expect(second == 5001)

        try allocator.release(first)
        let third = try allocator.allocate()
        // even after a release, it should continue to allocate in the range
        // before reusing a previous allocation on the stack.
        #expect(third == 5002)

        // now the next allocation should be our first port
        let reused = try allocator.allocate()
        #expect(reused == first)

        try allocator.release(third)
        let thirdReused = try allocator.allocate()
        #expect(thirdReused == third)
    }

    @Test
    func testRotatingReservedUInt32PortAllocator() throws {
        let lower = UInt32(5000)
        let allocator = try UInt32.rotatingAllocator(lower: lower, size: 3)

        try allocator.reserve(5001)
        let first = try allocator.allocate()
        #expect(first == 5000)
        // this should skip the reserved 5001
        let second = try allocator.allocate()
        #expect(second == 5002)

        // no release our reserved
        try allocator.release(5001)

        let third = try allocator.allocate()
        #expect(third == 5001)
    }
}
