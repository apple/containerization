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

import ContainerizationExtras
import Foundation

/// Neighbor Discovery option types as defined in RFC 4861 and subsequent RFCs
public enum NDOptionType: UInt8, Sendable {
    case sourceLinkLayerAddress = 1  // RFC 4861
    case targetLinkLayerAddress = 2  // RFC 4861
    case prefixInformation = 3  // RFC 4861
    case redirectedHeader = 4  // RFC 4861
    case mtu = 5  // RFC 4861
    case routeInformation = 24  // RFC 4191
    case recursiveDNSServer = 25  // RFC 8106
    case dnsSearchList = 31  // RFC 8106
    case captivePortal = 37  // RFC 7710
}

public struct NDOptionHeader: Bindable {
    public static let size: Int = 2

    public var type: NDOptionType

    public var lengthInUnits: UInt8

    public init(type: NDOptionType, lengthInUnits: UInt8) {
        self.type = type
        self.lengthInUnits = lengthInUnits
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let offset = buffer.copyIn(as: UInt8.self, value: type.rawValue, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NDOptionHeader", field: "type")
        }

        guard let offset = buffer.copyIn(as: UInt8.self, value: lengthInUnits, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "NDOptionHeader", field: "lengthInUnits")
        }

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: NDOption tx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NDOptionHeader", field: "type")
        }
        guard let value = NDOptionType(rawValue: value) else {
            throw BindError.recvMarshalFailure(type: "NDOptionHeader", field: "type")
        }
        type = value

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "NDOptionHeader", field: "lengthInUnits")
        }
        lengthInUnits = value

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: NDOption rx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }
}

public struct SourceLinkLayerAddress: Bindable {
    public static let size: Int = 6

    public var address: MACAddress

    public init(address: MACAddress) {
        self.address = address
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let offset = buffer.copyIn(buffer: address.bytes, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "SourceLinkLayerAddress", field: "address")
        }

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: source link layer address tx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset

        var bytes = [UInt8](repeating: 0, count: 6)
        guard let offset = buffer.copyOut(buffer: &bytes, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "SourceLinkLayerAddress", field: "bytes[0..<6]")
        }
        address = try MACAddress(bytes)

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: source link layer address rx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }
}

public struct PrefixInformation: Bindable {
    public static let size: Int = 30

    public var prefixLength: UInt8
    public var onLinkFlag: Bool
    public var autonomousFlag: Bool
    public var validLifetime: UInt32
    public var preferredLifetime: UInt32
    public var prefix: IPv6Address

    public init(
        prefixLength: UInt8,
        onLinkFlag: Bool,
        autonomousFlag: Bool,
        validLifetime: UInt32,
        preferredLifetime: UInt32,
        prefix: IPv6Address
    ) {
        self.prefixLength = prefixLength
        self.onLinkFlag = onLinkFlag
        self.autonomousFlag = autonomousFlag
        self.validLifetime = validLifetime
        self.preferredLifetime = preferredLifetime
        self.prefix = prefix
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset

        guard let offset = buffer.copyIn(as: UInt8.self, value: prefixLength, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "PrefixInformation", field: "prefixLength")
        }

        let flags = UInt8((onLinkFlag ? 0x80 : 0x00) | (autonomousFlag ? 0x40 : 0x00))
        guard let offset = buffer.copyIn(as: UInt8.self, value: flags, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "PrefixInformation", field: "flags")
        }

        guard let offset = buffer.copyIn(as: UInt32.self, value: validLifetime.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "PrefixInformation", field: "validLifetime")
        }

        guard let offset = buffer.copyIn(as: UInt32.self, value: preferredLifetime.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "PrefixInformation", field: "preferredLifetime")
        }

        guard let offset = buffer.copyIn(as: UInt32.self, value: 0, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "PrefixInformation", field: "reserved")
        }

        guard let offset = buffer.copyIn(buffer: prefix.bytes, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "PrefixInformation", field: "prefix")
        }

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: prefix information tx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "PrefixInformation", field: "prefixLength")
        }
        prefixLength = value

        guard let (offset, flags) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "PrefixInformation", field: "flags")
        }
        onLinkFlag = (flags & 0x80) != 0
        autonomousFlag = (flags & 0x40) != 0

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "PrefixInformation", field: "validLifetime")
        }
        validLifetime = UInt32(bigEndian: value)

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "PrefixInformation", field: "preferredLifetime")
        }
        preferredLifetime = UInt32(bigEndian: value)

        // Skip reserved field
        guard let (offset, _) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "PrefixInformation", field: "reserved")
        }

        var prefixBytes = [UInt8](repeating: 0, count: 16)
        guard let offset = buffer.copyOut(buffer: &prefixBytes, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "PrefixInformation", field: "bytes[0..<16]")
        }
        prefix = try IPv6Address(prefixBytes)

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: prefix information rx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }
}

public struct MTUOption: Bindable {
    public static let size: Int = 6

    public var mtu: UInt32

    public init(mtu: UInt32) {
        self.mtu = mtu
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset

        guard let offset = buffer.copyIn(as: UInt16.self, value: 0, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "MTUOption", field: "reserved")
        }

        guard let offset = buffer.copyIn(as: UInt32.self, value: mtu.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "MTUOption", field: "mtu")
        }

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: MTU option tx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset

        // Skip reserved field
        guard let (offset, _) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "MTUOption", field: "reserved")
        }

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "MTUOption", field: "mtu")
        }
        mtu = UInt32(bigEndian: value)

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: MTU option rx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }
}

public struct RecursiveDNSServer: Bindable {
    public static let size: Int = 6
    public var lifetime: UInt32

    public init(lifetime: UInt32) {
        self.lifetime = lifetime
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset

        guard let offset = buffer.copyIn(as: UInt16.self, value: 0, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RecursiveDNSServer", field: "reserved")
        }

        guard let offset = buffer.copyIn(as: UInt32.self, value: lifetime.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RecursiveDNSServer", field: "lifetime")
        }

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: recursive DNS server option tx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset

        // Skip reserved field
        guard let (offset, _) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RecursiveDNSServer", field: "reserved")
        }

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RecursiveDNSServer", field: "lifetime")
        }
        lifetime = UInt32(bigEndian: value)

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: recursive DNS server option rx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }
}

public struct IPv6AddressOptionData: Bindable {
    public static let size: Int = 16

    public var address: IPv6Address

    public init(address: IPv6Address) {
        self.address = address
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let offset = buffer.copyIn(buffer: address.bytes, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "IPv6AddressOptionData", field: "address")
        }

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: IPv6 address tx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset

        var bytes = [UInt8](repeating: 0, count: 16)
        guard let offset = buffer.copyOut(buffer: &bytes, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "IPv6AddressOptionData", field: "bytes[0..<16]")
        }
        address = try IPv6Address(bytes)

        let actualSize = offset - startOffset
        assert(actualSize == Self.size, "BUG: IPv6 address rx length mismatch - expected \(Self.size), got \(actualSize)")
        return offset
    }
}

// MARK: - NDOption Enum

public enum NDOption: Sendable {
    case sourceLinkLayerAddress(MACAddress)
    case prefixInformation(PrefixInformation)
    case mtu(UInt32)
    case recursiveDNSServer(lifetime: UInt32, addresses: [IPv6Address])

    /// Get the option type
    public var type: NDOptionType {
        switch self {
        case .sourceLinkLayerAddress: return .sourceLinkLayerAddress
        case .prefixInformation: return .prefixInformation
        case .mtu: return .mtu
        case .recursiveDNSServer: return .recursiveDNSServer
        }
    }

    /// Calculate length in 8-byte units (including 2-byte header)
    public var lengthInUnits: UInt8 {
        switch self {
        case .sourceLinkLayerAddress:
            return 1  // 2 (header) + 6 (MAC) = 8 bytes
        case .prefixInformation:
            return 4  // 2 (header) + 30 (data) = 32 bytes
        case .mtu:
            return 1  // 2 (header) + 6 (data) = 8 bytes
        case .recursiveDNSServer(_, let addresses):
            let totalBytes = 2 + 6 + (addresses.count * 16)
            return UInt8(totalBytes / 8)
        }
    }

    /// Serialize option to buffer (header + payload)
    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        var currentOffset = offset

        // Write header
        let header = NDOptionHeader(type: type, lengthInUnits: lengthInUnits)
        currentOffset = try header.appendBuffer(&buffer, offset: currentOffset)

        // Write payload based on type
        switch self {
        case .sourceLinkLayerAddress(let mac):
            let payload = SourceLinkLayerAddress(address: mac)
            currentOffset = try payload.appendBuffer(&buffer, offset: currentOffset)

        case .prefixInformation(let prefix):
            currentOffset = try prefix.appendBuffer(&buffer, offset: currentOffset)

        case .mtu(let mtu):
            let payload = MTUOption(mtu: mtu)
            currentOffset = try payload.appendBuffer(&buffer, offset: currentOffset)

        case .recursiveDNSServer(let lifetime, let addresses):
            let rdnss = RecursiveDNSServer(lifetime: lifetime)
            currentOffset = try rdnss.appendBuffer(&buffer, offset: currentOffset)
            for address in addresses {
                let addrData = IPv6AddressOptionData(address: address)
                currentOffset = try addrData.appendBuffer(&buffer, offset: currentOffset)
            }
        }

        return currentOffset
    }
}

// MARK: - Option Parsing

extension Array where Element == UInt8 {
    /// Parse all Neighbor Discovery options from this buffer
    /// - Parameters:
    ///   - offset: Starting offset in the buffer
    ///   - length: Total length of options data in bytes
    /// - Returns: Array of parsed NDOption values
    /// - Throws: BindError if parsing fails
    public mutating func parseNDOptions(offset: Int, length: Int) throws -> [NDOption] {
        var options: [NDOption] = []
        var currentOffset = offset
        let endOffset = offset + length

        while currentOffset < endOffset {
            // Read header fields manually to handle unknown types
            guard let (typeOffset, typeValue) = self.copyOut(as: UInt8.self, offset: currentOffset) else {
                throw BindError.recvMarshalFailure(type: "NDOption", field: "type")
            }

            guard let (lengthOffset, lengthInUnits) = self.copyOut(as: UInt8.self, offset: typeOffset) else {
                throw BindError.recvMarshalFailure(type: "NDOption", field: "lengthInUnits")
            }

            guard lengthInUnits > 0 else {
                throw BindError.recvMarshalFailure(type: "NDOption", field: "lengthInUnits")
            }

            currentOffset = lengthOffset
            let payloadLength = Int(lengthInUnits) * 8 - NDOptionHeader.size

            // Check if this is a known option type
            guard let optionType = NDOptionType(rawValue: typeValue) else {
                // Unknown option type - skip it
                print("Warning: skipping unknown ND option type \(typeValue)")
                currentOffset += payloadLength
                continue
            }

            // Parse payload based on type
            let option: NDOption
            switch optionType {
            case .sourceLinkLayerAddress:
                var payload = SourceLinkLayerAddress(address: MACAddress(0))
                currentOffset = try payload.bindBuffer(&self, offset: currentOffset)
                option = .sourceLinkLayerAddress(payload.address)

            case .prefixInformation:
                var payload = PrefixInformation(
                    prefixLength: 0, onLinkFlag: false, autonomousFlag: false,
                    validLifetime: 0, preferredLifetime: 0, prefix: IPv6Address(0)
                )
                currentOffset = try payload.bindBuffer(&self, offset: currentOffset)
                option = .prefixInformation(payload)

            case .mtu:
                var payload = MTUOption(mtu: 0)
                currentOffset = try payload.bindBuffer(&self, offset: currentOffset)
                option = .mtu(payload.mtu)

            case .recursiveDNSServer:
                var rdnss = RecursiveDNSServer(lifetime: 0)
                currentOffset = try rdnss.bindBuffer(&self, offset: currentOffset)

                // Parse remaining addresses
                let remainingBytes = payloadLength - RecursiveDNSServer.size
                let addressCount = remainingBytes / 16
                var addresses: [IPv6Address] = []
                for _ in 0..<addressCount {
                    var addrData = IPv6AddressOptionData(address: IPv6Address(0))
                    currentOffset = try addrData.bindBuffer(&self, offset: currentOffset)
                    addresses.append(addrData.address)
                }
                option = .recursiveDNSServer(lifetime: rdnss.lifetime, addresses: addresses)

            default:
                // Other known types we don't handle yet - skip them
                print("Warning: skipping unsupported ND option type \(optionType.rawValue)")
                currentOffset += payloadLength
                continue
            }

            options.append(option)
        }

        return options
    }
}
