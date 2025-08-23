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

@testable import ContainerizationExtras

struct IndexedAddressAllocatorTests {

    // MARK: - Basic Allocation Tests

    @Test func allocateSimpleSequence() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 5,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in String(index) }
        )

        // Should allocate sequentially from 0
        #expect(try allocator.allocate() == "0")
        #expect(try allocator.allocate() == "1")
        #expect(try allocator.allocate() == "2")
        #expect(try allocator.allocate() == "3")
        #expect(try allocator.allocate() == "4")
    }

    @Test func allocateThrowsWhenFull() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 2,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in String(index) }
        )

        // Fill the allocator
        _ = try allocator.allocate()
        _ = try allocator.allocate()

        // Should throw when full
        #expect(throws: AllocatorError.self) {
            _ = try allocator.allocate()
        }
    }

    @Test func allocateThrowsWhenDisabled() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 3,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in String(index) }
        )

        let success = allocator.disableAllocator()
        #expect(success == true)  // Should succeed when no allocations

        #expect(throws: AllocatorError.self) {
            _ = try allocator.allocate()
        }
    }

    // MARK: - Reserve and Release Tests

    @Test func reserveAddressSuccessfully() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 5,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in String(index) }
        )

        try allocator.reserve("2")

        // Should skip reserved address
        #expect(try allocator.allocate() == "0")
        #expect(try allocator.allocate() == "1")
        #expect(try allocator.allocate() == "3")  // Skips "2"
    }

    @Test func reserveAlreadyAllocatedAddress() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 5,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in String(index) }
        )

        _ = try allocator.allocate()  // Allocates "0"

        #expect(throws: AllocatorError.self) {
            try allocator.reserve("0")  // Should fail - already allocated
        }
    }

    @Test func releaseAllocatedAddress() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 3,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in String(index) }
        )

        let address = try allocator.allocate()  // Gets "0"
        try allocator.release(address)

        // Should be able to allocate the released address again
        #expect(try allocator.allocate() == "0")
    }

    @Test func releaseNonAllocatedAddress() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 5,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in String(index) }
        )

        #expect(throws: AllocatorError.self) {
            try allocator.release("2")  // Not allocated
        }
    }

    @Test func disableAllocatorFailsWithActiveAllocations() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 3,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in String(index) }
        )

        _ = try allocator.allocate()  // Make an allocation

        let success = allocator.disableAllocator()
        #expect(success == false)  // Should fail when allocations exist

        // Should still be able to allocate since disable failed
        _ = try allocator.allocate()
    }

    // MARK: - Error Handling Tests

    @Test func reserveInvalidAddressThrows() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 3,
            addressToIndex: { address in
                let val = Int(address)
                return (val != nil && val! >= 0 && val! < 3) ? val : nil
            },
            indexToAddress: { index in String(index) }
        )

        #expect(throws: AllocatorError.self) {
            try allocator.reserve("999")  // Out of range
        }
    }

    @Test func releaseInvalidAddressThrows() throws {
        let allocator = IndexedAddressAllocator<String>(
            size: 3,
            addressToIndex: { address in
                let val = Int(address)
                return (val != nil && val! >= 0 && val! < 3) ? val : nil
            },
            indexToAddress: { index in String(index) }
        )

        #expect(throws: AllocatorError.self) {
            try allocator.release("999")  // Out of range
        }
    }

    // MARK: - IPv4Address Integration Test

    @Test func ipv4AddressAllocatorIntegration() throws {
        let baseIP: UInt32 = 0xC0A8_0001  // 192.168.0.1
        let allocator = try IPv4Address.allocator(lower: baseIP, size: 3)

        let ip1 = try allocator.allocate()
        let ip2 = try allocator.allocate()
        let ip3 = try allocator.allocate()

        #expect(ip1.value == baseIP)
        #expect(ip2.value == baseIP + 1)
        #expect(ip3.value == baseIP + 2)

        // Should be full now
        #expect(throws: AllocatorError.self) {
            _ = try allocator.allocate()
        }
    }
}
