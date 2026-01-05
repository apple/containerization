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

public struct AddressError: Error, Equatable, Hashable, CustomStringConvertible {
    public var description: String {
        String(describing: self.base)
    }

    @usableFromInline
    enum Base: Equatable, Hashable, Sendable {
        case unableToParse
        case invalidZoneIdentifier
        case invalidIPv4Suffix
        case multipleEllipsis
        case invalidHexGroup
        case malformedAddress
        case incompleteAddress
    }

    @usableFromInline
    let base: Base

    @inlinable
    init(_ base: Base) { self.base = base }

    public static var unableToParse: Self {
        Self(.unableToParse)
    }

    public static var invalidZoneIdentifier: Self {
        Self(.invalidZoneIdentifier)
    }

    public static var invalidIPv4SuffixInIPv6Address: Self {
        Self(.invalidIPv4Suffix)
    }

    public static var multipleEllipsis: Self {
        Self(.multipleEllipsis)
    }

    public static var invalidHexGroup: Self {
        Self(.invalidHexGroup)
    }

    public static var malformedAddress: Self {
        Self(.malformedAddress)
    }

    public static var incompleteAddress: Self {
        Self(.incompleteAddress)
    }
}
