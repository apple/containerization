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

/// Conforming objects can allocate and free various address types.
public protocol AddressAllocator<AddressType>: Sendable {
    associatedtype AddressType: Sendable

    /// Allocate a new address.
    func allocate() throws -> AddressType

    /// Attempt to reserve a specific address.
    func reserve(_ address: AddressType) throws

    /// Free an allocated address.
    func release(_ address: AddressType) throws

    /// If no addresses are allocated, prevent future allocations and return true.
    func disableAllocator() -> Bool
}

/// Errors that a type implementing AddressAllocator should throw.
public enum AllocatorError: Swift.Error, CustomStringConvertible, Equatable {
    case allocatorDisabled
    case allocatorFull
    case alreadyAllocated(_ address: String)
    case invalidAddress(_ index: String)
    case invalidArgument(_ msg: String)
    case invalidIndex(_ index: Int)
    case notAllocated(_ address: String)
    case rangeExceeded

    public var description: String {
        switch self {
        case .allocatorDisabled:
            return "the allocator is shutting down"
        case .allocatorFull:
            return "no free indices are available for allocation"
        case .alreadyAllocated(let address):
            return "cannot choose already-allocated address \(address)"
        case .invalidAddress(let address):
            return "cannot create index using address \(address)"
        case .invalidArgument(let msg):
            return "invalid argument: \(msg)"
        case .invalidIndex(let index):
            return "cannot create address using index \(index)"
        case .notAllocated(let address):
            return "cannot free unallocated address \(address)"
        case .rangeExceeded:
            return "cannot create allocator that overflows maximum address value"
        }
    }
}
