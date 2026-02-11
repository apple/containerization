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

import Collections
import Synchronization

/// Maps a network address to an array index value, or nil in the case of a domain error.
package typealias AddressToIndexTransform<AddressType> = @Sendable (AddressType) -> Int?

/// Maps an array index value to a network address, or nil in the case of a domain error.
package typealias IndexToAddressTransform<AddressType> = @Sendable (Int) -> AddressType?

package final class IndexedAddressAllocator<AddressType: CustomStringConvertible & Sendable>: AddressAllocator {
    private class State {
        var allocations: BitArray
        var enabled: Bool
        var allocationCount: Int
        let addressToIndex: AddressToIndexTransform<AddressType>
        let indexToAddress: IndexToAddressTransform<AddressType>

        init(
            size: Int,
            addressToIndex: @escaping AddressToIndexTransform<AddressType>,
            indexToAddress: @escaping IndexToAddressTransform<AddressType>
        ) {
            self.allocations = BitArray.init(repeating: false, count: size)
            self.enabled = true
            self.allocationCount = 0
            self.addressToIndex = addressToIndex
            self.indexToAddress = indexToAddress
        }
    }

    private let state: Mutex<State>

    /// Create an allocator with specified size and index mappings.
    package init(
        size: Int,
        addressToIndex: @escaping AddressToIndexTransform<AddressType>,
        indexToAddress: @escaping IndexToAddressTransform<AddressType>
    ) {
        let state = State(
            size: size,
            addressToIndex: addressToIndex,
            indexToAddress: indexToAddress
        )
        self.state = Mutex(state)
    }

    public func allocate() throws -> AddressType {
        try self.state.withLock { state in
            guard state.enabled else {
                throw AllocatorError.allocatorDisabled
            }

            guard let index = state.allocations.firstIndex(of: false) else {
                throw AllocatorError.allocatorFull
            }

            guard let address = state.indexToAddress(index) else {
                throw AllocatorError.invalidIndex(index)
            }

            state.allocations[index] = true
            state.allocationCount += 1
            return address
        }
    }

    package func reserve(_ address: AddressType) throws {
        try self.state.withLock { state in
            guard state.enabled else {
                throw AllocatorError.allocatorDisabled
            }

            guard let index = state.addressToIndex(address) else {
                throw AllocatorError.invalidAddress(address.description)
            }

            guard !state.allocations[index] else {
                throw AllocatorError.alreadyAllocated("\(address.description)")
            }

            state.allocations[index] = true
            state.allocationCount += 1
        }

    }

    package func release(_ address: AddressType) throws {
        try self.state.withLock { state in
            guard let index = state.addressToIndex(address) else {
                throw AllocatorError.invalidAddress(address.description)
            }

            guard state.allocations[index] else {
                throw AllocatorError.notAllocated("\(address.description)")
            }

            state.allocations[index] = false
            state.allocationCount -= 1
        }
    }

    package func disableAllocator() -> Bool {
        self.state.withLock { state in
            guard state.allocationCount == 0 else {
                return false
            }
            state.enabled = false
            return true
        }
    }
}
