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

import Synchronization

package final class RotatingAddressAllocator: AddressAllocator {
    package typealias AddressType = UInt32

    private struct State {
        var allocations: [AddressType]
        var enabled: Bool
        var allocationCount: Int
        let addressToIndex: AddressToIndexTransform<AddressType>
        let indexToAddress: IndexToAddressTransform<AddressType>

        init(
            size: UInt32,
            addressToIndex: @escaping AddressToIndexTransform<AddressType>,
            indexToAddress: @escaping IndexToAddressTransform<AddressType>
        ) {
            self.allocations = [UInt32](0..<size)
            self.enabled = true
            self.allocationCount = 0
            self.addressToIndex = addressToIndex
            self.indexToAddress = indexToAddress
        }
    }

    private let state: Mutex<State>

    /// Create an allocator with specified size and index mappings.
    package init(
        size: UInt32,
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

            guard state.allocations.count > 0 else {
                throw AllocatorError.allocatorFull
            }

            let value = state.allocations.removeFirst()

            guard let address = state.indexToAddress(Int(value)) else {
                throw AllocatorError.invalidIndex(Int(value))
            }

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

            let i = state.allocations.firstIndex(of: UInt32(index))
            guard let i else {
                throw AllocatorError.alreadyAllocated("\(address.description)")
            }

            _ = state.allocations.remove(at: i)
            state.allocationCount += 1
        }
    }

    package func release(_ address: AddressType) throws {
        try self.state.withLock { state in
            guard let index = (state.addressToIndex(address)) else {
                throw AllocatorError.invalidAddress(address.description)
            }
            let value = UInt32(index)

            guard !state.allocations.contains(value) else {
                throw AllocatorError.notAllocated("\(address.description)")
            }

            state.allocations.append(value)
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
