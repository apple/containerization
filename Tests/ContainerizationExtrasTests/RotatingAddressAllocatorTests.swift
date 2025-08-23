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

struct RotatingAddressAllocatorTests {

    // MARK: - Basic Allocation Tests

    @Test func allocateRemovesFromFrontOfArray() throws {
        let allocator = RotatingAddressAllocator(
            size: 5,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        // Should allocate in order: 0, 1, 2, 3, 4 (removeFirst behavior)
        #expect(try allocator.allocate() == 0)
        #expect(try allocator.allocate() == 1)
        #expect(try allocator.allocate() == 2)
        #expect(try allocator.allocate() == 3)
        #expect(try allocator.allocate() == 4)
    }

    @Test func allocateThrowsWhenArrayEmpty() throws {
        let allocator = RotatingAddressAllocator(
            size: 2,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        // Exhaust the allocator
        _ = try allocator.allocate()
        _ = try allocator.allocate()

        // Should throw when array is empty
        #expect(throws: AllocatorError.self) {
            _ = try allocator.allocate()
        }
    }

    @Test func allocateThrowsWhenDisabled() throws {
        let allocator = RotatingAddressAllocator(
            size: 3,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        let success = allocator.disableAllocator()
        #expect(success == true)

        #expect(throws: AllocatorError.self) {
            _ = try allocator.allocate()
        }
    }

    // MARK: - Reserve Tests

    @Test func reserveRemovesSpecificValueFromArray() throws {
        let allocator = RotatingAddressAllocator(
            size: 5,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        // Reserve address 2 (should remove index 2 from array)
        try allocator.reserve(2)

        // Next allocations should skip the reserved value
        #expect(try allocator.allocate() == 0)
        #expect(try allocator.allocate() == 1)
        #expect(try allocator.allocate() == 3)  // Skips 2
        #expect(try allocator.allocate() == 4)
    }

    @Test func reserveThrowsForAlreadyAllocatedAddress() throws {
        let allocator = RotatingAddressAllocator(
            size: 5,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        _ = try allocator.allocate()  // Allocates 0, removes it from array

        #expect(throws: AllocatorError.self) {
            try allocator.reserve(0)  // Should fail - not in array anymore
        }
    }

    @Test func reserveThrowsWhenDisabled() throws {
        let allocator = RotatingAddressAllocator(
            size: 3,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        _ = allocator.disableAllocator()

        #expect(throws: AllocatorError.self) {
            try allocator.reserve(1)
        }
    }

    // MARK: - Release Tests

    @Test func releaseAddsBackToEndOfArray() throws {
        let allocator = RotatingAddressAllocator(
            size: 3,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        let allocated = try allocator.allocate()  // Gets 0
        try allocator.release(allocated)

        // Next allocation should be 1 (not 0), since 0 was appended to end
        #expect(try allocator.allocate() == 1)
        #expect(try allocator.allocate() == 2)
        #expect(try allocator.allocate() == 0)  // Now gets the released one
    }

    @Test func releaseThrowsForAlreadyAvailableAddress() throws {
        let allocator = RotatingAddressAllocator(
            size: 3,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        #expect(throws: AllocatorError.self) {
            try allocator.release(1)  // Still in array, not allocated
        }
    }

    @Test func releaseThrowsForInvalidAddress() throws {
        let allocator = RotatingAddressAllocator(
            size: 3,
            addressToIndex: { address in
                // Only accept 0, 1, 2
                (address >= 0 && address <= 2) ? Int(address) : nil
            },
            indexToAddress: { index in UInt32(index) }
        )

        #expect(throws: AllocatorError.self) {
            try allocator.release(999)  // Invalid address
        }
    }

    // MARK: - Disable Allocator Tests

    @Test func disableAllocatorFailsWithActiveAllocations() throws {
        let allocator = RotatingAddressAllocator(
            size: 3,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        _ = try allocator.allocate()  // Make allocation (increments count)

        let success = allocator.disableAllocator()
        #expect(success == false)  // Should fail due to active allocations

        // Should still work since disable failed
        _ = try allocator.allocate()
    }

    @Test func disableAllocatorSucceedsWhenEmpty() throws {
        let allocator = RotatingAddressAllocator(
            size: 2,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        let success = allocator.disableAllocator()
        #expect(success == true)  // Should succeed with no allocations
    }

    // MARK: - Transform Function Tests

    @Test func invalidIndexTransformThrowsError() throws {
        let allocator = RotatingAddressAllocator(
            size: 3,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in
                // Return nil for index 1 to simulate invalid transform
                (index == 1) ? nil : UInt32(index)
            }
        )

        _ = try allocator.allocate()  // Gets 0, works fine

        #expect(throws: AllocatorError.self) {
            _ = try allocator.allocate()  // Tries index 1, should throw invalidIndex
        }
    }

    // MARK: - Complex Scenario Tests

    @Test func allocateReserveReleaseSequence() throws {
        let allocator = RotatingAddressAllocator(
            size: 4,
            addressToIndex: { address in Int(address) },
            indexToAddress: { index in UInt32(index) }
        )

        // Initial: [0, 1, 2, 3]
        let addr1 = try allocator.allocate()  // Gets 0, array: [1, 2, 3]
        #expect(addr1 == 0)

        try allocator.reserve(2)  // Removes 2, array: [1, 3]

        let addr2 = try allocator.allocate()  // Gets 1, array: [3]
        #expect(addr2 == 1)

        try allocator.release(addr1)  // Releases 0, array: [3, 0]

        let addr3 = try allocator.allocate()  // Gets 3, array: [0]
        #expect(addr3 == 3)

        let addr4 = try allocator.allocate()  // Gets 0, array: []
        #expect(addr4 == 0)

        // Should be full now
        #expect(throws: AllocatorError.self) {
            _ = try allocator.allocate()
        }
    }
}
