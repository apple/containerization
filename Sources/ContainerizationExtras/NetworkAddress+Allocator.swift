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

extension IPv4Address {
    /// Creates an allocator for IPv4 addresses.
    public static func allocator(lower: UInt32, size: Int) throws -> any AddressAllocator<IPv4Address> {
        // NOTE: 2^31 - 1 size limit in the very improbable case that we run on 32-bit.
        guard size > 0 && size < Int.max && 0xffff_ffff - lower >= size - 1 else {
            throw AllocatorError.rangeExceeded
        }
        return IndexedAddressAllocator(
            size: size,
            addressToIndex: { address in
                guard address.value >= lower && address.value - lower <= UInt32(size) else {
                    return nil
                }
                return Int(address.value - lower)
            },
            indexToAddress: { IPv4Address(lower + UInt32($0)) }
        )
    }
}

extension UInt16 {
    /// Creates an allocator for TCP/UDP ports and other UInt16 values.
    public static func allocator(lower: UInt16, size: Int) throws -> any AddressAllocator<UInt16> {
        guard 0xffff - lower + 1 >= size else {
            throw AllocatorError.rangeExceeded
        }

        return IndexedAddressAllocator(
            size: size,
            addressToIndex: { address in
                guard address >= lower && address <= lower + UInt16(size) else {
                    return nil
                }
                return Int(address - lower)
            },
            indexToAddress: { lower + UInt16($0) }
        )
    }
}

extension UInt32 {
    /// Creates an allocator for vsock ports, or any UInt32 values.
    public static func allocator(lower: UInt32, size: Int) throws -> any AddressAllocator<UInt32> {
        guard 0xffff_ffff - lower + 1 >= size else {
            throw AllocatorError.rangeExceeded
        }

        return IndexedAddressAllocator(
            size: size,
            addressToIndex: { address in
                guard address >= lower && address <= lower + UInt32(size) else {
                    return nil
                }
                return Int(address - lower)
            },
            indexToAddress: { lower + UInt32($0) }
        )
    }

    /// Creates a rotating allocator for vsock ports, or any UInt32 values.
    public static func rotatingAllocator(lower: UInt32, size: UInt32) throws -> any AddressAllocator<UInt32> {
        guard 0xffff_ffff - lower + 1 >= size else {
            throw AllocatorError.rangeExceeded
        }

        return RotatingAddressAllocator(
            size: size,
            addressToIndex: { address in
                guard address >= lower && address <= lower + UInt32(size) else {
                    return nil
                }
                return Int(address - lower)
            },
            indexToAddress: { lower + UInt32($0) }
        )
    }
}

extension Character {
    private static let deviceLetters = Array("abcdefghijklmnopqrstuvwxyz")

    /// Creates an allocator for block device tags, or any character values.
    public static func blockDeviceTagAllocator() -> any AddressAllocator<Character> {
        IndexedAddressAllocator(
            size: Self.deviceLetters.count,
            addressToIndex: { address in
                Self.deviceLetters.firstIndex(of: address)
            },
            indexToAddress: { Self.deviceLetters[$0] }
        )
    }
}
