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

extension IPv6Address {
    /// Parses an IPv6 address string into an IPv6Address instance.
    ///
    /// Follows RFC 4291 and RFC 5952.
    ///
    /// This function supports standard IPv6 notation including:
    /// - Full addresses: `2001:0db8:0000:0042:0000:8a2e:0370:7334`
    /// - Zero compression: `2001:db8::8a2e:370:7334`
    /// - Leading zero omission: `2001:db8:0:42:0:8a2e:370:7334`
    /// - Unspecified address: `::`
    /// - Zone identifiers: `fe80::1%eth0`
    ///
    /// - Parameter input: IPv6 address string (with optional zone identifier after %)
    /// - Returns: An `IPv6Address` instance representing the parsed address
    ///
    /// ## Example Usage
    /// ```swift
    /// let addr1 = try IPv6Address.parse("2001:db8::1")
    /// let addr2 = try IPv6Address.parse("::") // Unspecified address
    /// let addr3 = try IPv6Address.parse("fe80::1%eth0") // With zone identifier
    /// ```
    static func parse(_ input: String) throws -> IPv6Address {
        var ipBytes = [UInt8](repeating: 0, count: 16)
        var ellipsisPosition: Int?

        // Extract zone identifier
        let (address, zone) = try extractZoneIdentifier(from: input)

        // RFC 4291 Section 2.2.3: IPv4 suffix must be at the end (last 32 bits)
        var remainingAddress = address
        var ipv6ByteLimit = 16  // Maximum bytes available for IPv6 hex groups
        var hasIPv4Suffix = false

        // check if the IPv6 address has IPv4 address in it.
        if let (ipv6Part, ipv4Bytes) = try extractIPv4Suffix(from: address) {
            // If IPv4 present, save directly to last 4 bytes.
            ipBytes[12] = ipv4Bytes[0]
            ipBytes[13] = ipv4Bytes[1]
            ipBytes[14] = ipv4Bytes[2]
            ipBytes[15] = ipv4Bytes[3]

            // Update address and limit IPv6 parsing to first 12 bytes (6 groups max)
            remainingAddress = ipv6Part
            ipv6ByteLimit = 12
            hasIPv4Suffix = true
        }

        // Handle leading ellipsis in the IPv6 part
        if remainingAddress.utf8.starts(with: [58, 58]) {  // "::"
            ellipsisPosition = 0
            remainingAddress = String(remainingAddress.dropFirst(2))

            // Special case: "::" represents the unspecified address (all zeros)
            // But if we have IPv4 suffix, the IPv4 bytes are already set correctly
            if remainingAddress.isEmpty {
                // If we have IPv4 suffix, ipBytes already has the IPv4 data, just return
                if hasIPv4Suffix {
                    return Self(ipBytes, zone: zone)
                }

                // Pure "::" - Return the unspecified address, handling zone identifiers
                if let zone = zone, !zone.isEmpty {
                    return Self(ipBytes, zone: zone)
                }
                return .unspecified
            }
        }

        // Parse IPv6 hex groups up to the byte limit
        var byteIndex = 0
        let utf8 = remainingAddress.utf8
        var currentPosition = utf8.startIndex

        while byteIndex < ipv6ByteLimit && currentPosition < utf8.endIndex {
            let (hexValue, nextPosition) = try parseHexadecimal(
                from: utf8,
                startingAt: currentPosition
            )

            // Store the UInt16 in network-byte order
            ipBytes[byteIndex] = UInt8(hexValue >> 8)
            ipBytes[byteIndex + 1] = UInt8(hexValue & 0xFF)
            byteIndex += 2
            currentPosition = nextPosition

            // Terminate early if we have consumed the whole string
            if currentPosition == utf8.endIndex {
                break
            }

            // Parse separator and handle ellipsis detection
            currentPosition = try skipColonSeparator(
                from: utf8,
                at: currentPosition,
                currentByteIndex: byteIndex,
                ellipsisPosition: &ellipsisPosition
            )
        }

        // Validate complete consumption of input
        guard currentPosition >= utf8.endIndex else {
            throw AddressError.malformedAddress
        }

        // Apply ellipsis expansion for the IPv6 portion
        try expandEllipsis(
            in: &ipBytes,
            parsedBytes: byteIndex,
            ellipsisPosition: ellipsisPosition,
            byteLimit: ipv6ByteLimit
        )
        let value = ipBytes.reduce(UInt128(0)) { ($0 << 8) | UInt128($1) }
        return Self(value, zone: zone)
    }

    // MARK: - Helper Functions

    /// Extracts IPv4 suffix if present at the end of the address
    ///
    /// Follows: RFC 4291 Section 2.2.3: Alternative form x:x:x:x:x:x:d.d.d.d
    /// IPv4 must be the last 32 bits and preceded by a colon
    ///
    /// - Parameter input: The IPv6 address string to check
    /// - Returns: Optional tuple of (IPv6 part without IPv4, IPv4 bytes array) if IPv4 found, nil otherwise
    /// - Throws: `AddressError.invalidIPv4Suffix` for invalid IPv4 addresses
    internal static func extractIPv4Suffix(from input: String) throws -> (String, [UInt8])? {
        // must contain a dot to be IPv4
        guard input.utf8.contains(46) else {  // ASCII '.'
            return nil
        }

        // IPv4 address must be present after last colon
        guard let lastColonIndex = input.lastIndex(of: ":") else {
            return nil
        }

        // TODO: maybe refactor for performance
        let afterColon = input.index(after: lastColonIndex)
        guard afterColon < input.endIndex else {
            return nil
        }

        let possibleIPv4 = String(input[afterColon...])
        guard let ipv4Value = try? IPv4Address.parse(possibleIPv4) else {
            throw AddressError.invalidIPv4SuffixInIPv6Address
        }

        // Check if lastColonIndex is the second ':' of '::'. If so, ensure to include it.
        let isDoubleColon = lastColonIndex > input.startIndex && input[input.index(before: lastColonIndex)] == ":"
        let ipv6Part = isDoubleColon ? String(input[...lastColonIndex]) : String(input[..<lastColonIndex])
        return (ipv6Part, IPv4Address.bytes(ipv4Value))
    }

    /// Extracts zone identifier
    ///
    /// - Parameter input: The full IPv6 address string with potential zone identifier
    /// - Returns: Tuple of (address part, optional zone identifier)
    /// - Throws: `AddressError.invalidZoneIdentifier` for malformed zone identifiers
    private static func extractZoneIdentifier(from input: String) throws -> (String, String?) {
        guard let percentIndex = input.lastIndex(of: "%") else {
            return (input, nil)
        }

        let zoneStartIndex = input.index(after: percentIndex)
        guard zoneStartIndex < input.endIndex else {
            throw AddressError.invalidZoneIdentifier
        }

        let addressPart = String(input[..<percentIndex])
        let zoneIdentifier = String(input[zoneStartIndex...])

        return (addressPart, zoneIdentifier)
    }

    /// Parses a hexadecimal group from an IPv6 address component.
    ///
    /// - Parameters:
    ///   - utf8: The UTF-8 view to parse from
    ///   - startIndex: Starting position in the UTF-8 view
    /// - Returns: Tuple of (parsed hex value as UInt16, next position after parsed digits)
    /// - Throws: `AddressError.invalidHexGroup` if no valid hex digits are found
    ///
    /// ## Example
    /// ```swift
    /// let utf8 = "2001:db8::1".utf8
    /// let (value, nextPos) = try parseHexadecimal(from: utf8, startingAt: utf8.startIndex)
    /// // value = 0x2001, nextPos points to ':'
    /// ```
    @inlinable
    internal static func parseHexadecimal(
        from group: String.UTF8View,
        startingAt startIndex: String.UTF8View.Index
    ) throws -> (UInt16, String.UTF8View.Index) {
        var accumulator: UInt16 = 0
        var digitCount = 0
        var currentIndex = startIndex

        while currentIndex < group.endIndex && digitCount < 4 {
            let byte = group[currentIndex]

            // Fast hex digit parsing using ASCII values
            let hexValue: UInt16
            if byte >= 48 && byte <= 57 {  // '0'-'9'
                hexValue = UInt16(byte - 48)
            } else if byte >= 65 && byte <= 70 {  // 'A'-'F'
                hexValue = UInt16(byte - 65 + 10)
            } else if byte >= 97 && byte <= 102 {  // 'a'-'f'
                hexValue = UInt16(byte - 97 + 10)
            } else {
                break  // Not a hex digit
            }

            accumulator = (accumulator << 4) + hexValue
            digitCount += 1
            currentIndex = group.index(after: currentIndex)
        }

        guard digitCount > 0 else {
            // No hex digits found
            throw AddressError.invalidHexGroup
        }
        return (accumulator, currentIndex)
    }

    /// Parses a colon separator between IPv6 groups and detects ellipsis notation (::).
    ///
    /// - Parameters:
    ///   - utf8: The UTF-8 view being parsed
    ///   - position: Current position in the UTF-8 view (must point to a colon)
    ///   - currentByteIndex: Current byte index in the IP array
    ///   - ellipsisPosition: Inout parameter tracking ellipsis position
    /// - Returns: Next position in the UTF-8 view after parsing separator
    ///
    /// ## Example
    /// ```swift
    /// let utf8 = "2001:db8::1".utf8
    /// var ellipsisPos: Int? = nil
    /// // After parsing "2001", position points to first ':'
    /// let nextPos = try skipColonSeparator(from: utf8, at: position,
    ///                                       currentByteIndex: 2,
    ///                                       ellipsisPosition: &ellipsisPos)
    /// // For single colon: nextPos points to 'd' in 'db8'
    /// // For double colon (::): ellipsisPos = 2, nextPos points to '1'
    /// ```
    private static func skipColonSeparator(
        from group: String.UTF8View,
        at position: String.UTF8View.Index,
        currentByteIndex: Int,
        ellipsisPosition: inout Int?
    ) throws -> String.UTF8View.Index {
        // Expect colon separator
        guard group[position] == 58 else {  // ASCII ':'
            throw AddressError.malformedAddress
        }

        let afterFirstColon = group.index(after: position)
        guard afterFirstColon < group.endIndex else {
            // Trailing colon not allowed
            throw AddressError.malformedAddress
        }

        // Check for double colon, return position after that
        if group[afterFirstColon] == 58 {  // ASCII ':'
            guard ellipsisPosition == nil else {
                // Multiple :: not allowed
                throw AddressError.multipleEllipsis
            }
            ellipsisPosition = currentByteIndex
            let afterSecondColon = group.index(after: afterFirstColon)
            return afterSecondColon
        }
        return afterFirstColon
    }

    /// Expands ellipsis for IPv6 addresses
    ///
    /// - Parameters:
    ///   - ipBytes: Inout array of IP bytes to modify
    ///   - parsedBytes: Number of bytes already parsed for IPv6 groups
    ///   - ellipsisPosition: Optional position where ellipsis was found
    ///   - byteLimit: Maximum bytes available for IPv6 (16 for pure IPv6, 12 if IPv4 suffix present)
    /// - Throws: `AddressError.incompleteAddress` for invalid address lengths
    private static func expandEllipsis(
        in ipBytes: inout [UInt8],
        parsedBytes: Int,
        ellipsisPosition: Int?,
        byteLimit: Int = 16
    ) throws {
        guard let ellipsisPosition = ellipsisPosition else {
            // No ellipsis - validate we have exactly filled the available bytes
            guard parsedBytes == byteLimit else {
                throw AddressError.incompleteAddress  // Incomplete address without ellipsis
            }
            return
        }

        // Calculate expansion within the byte limit
        let bytesToExpand = byteLimit - parsedBytes
        guard bytesToExpand > 0 else {
            throw AddressError.malformedAddress  // No room for ellipsis expansion
        }

        let suffixBytes = Array(ipBytes[ellipsisPosition..<parsedBytes])
        let targetStartIndex = byteLimit - suffixBytes.count

        // Clear the expansion area using Swift's range-based assignment
        for i in ellipsisPosition..<targetStartIndex {
            ipBytes[i] = 0
        }

        // Place suffix at the end of the IPv6 section using Swift's collection assignment
        for (offset, byte) in suffixBytes.enumerated() {
            ipBytes[targetStartIndex + offset] = byte
        }
    }

}
