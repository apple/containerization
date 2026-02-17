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

public enum ICMPv4MessageType: UInt8, Sendable {
    case echoReply = 0
    case destinationUnreachable = 3
    case sourceQuench = 4  // Deprecated (RFC 6633)
    case redirect = 5
    case echoRequest = 8
    case routerAdvertisement = 9
    case routerSolicitation = 10
    case timeExceeded = 11
    case parameterProblem = 12
    case timestampRequest = 13
    case timestampReply = 14
    case informationRequest = 15  // Obsolete
    case informationReply = 16  // Obsolete
    case addressMaskRequest = 17  // Deprecated
    case addressMaskReply = 18  // Deprecated
    case traceroute = 30  // Deprecated (RFC 1393)
}

public struct ICMPv4Header: Bindable {
    public static let size: Int = 4

    public var type: ICMPv4MessageType

    public var code: UInt8

    public init(type: ICMPv4MessageType = .echoReply, code: UInt8 = 0) {
        self.type = type
        self.code = code
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let offset = buffer.copyIn(as: UInt8.self, value: type.rawValue, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "ICMPv4Header", field: "type")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: code, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "ICMPv4Header", field: "code")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: UInt16(0), offset: offset) else {
            throw BindError.sendMarshalFailure(type: "ICMPv4Header", field: "checksum")
        }

        assert(offset - startOffset == Self.size, "BUG: echo appendBuffer length mismatch - expected \(Self.size), got \(offset - startOffset)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "ICMPv4Header", field: "type")
        }
        guard let type = ICMPv4MessageType(rawValue: value) else {
            throw BindError.recvMarshalFailure(type: "ICMPv4Header", field: "type")
        }
        self.type = type

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "ICMPv4Header", field: "code")
        }
        self.code = value

        let offsetSkippingChecksum = offset + MemoryLayout<UInt16>.size

        assert(offsetSkippingChecksum - startOffset == Self.size, "BUG: echo bindBuffer length mismatch - expected \(Self.size), got \(offsetSkippingChecksum - startOffset)")
        return offsetSkippingChecksum
    }

    /// Calculate ICMPv4 checksum (16-bit one's complement of one's complement sum)
    public static func checksum(buffer: [UInt8], offset: Int, length: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = offset
        let end = offset + length

        // Sum up 16-bit words
        while i < end - 1 {
            let word = UInt32(buffer[i]) << 8 | UInt32(buffer[i + 1])
            sum += word
            i += 2
        }

        // Add remaining byte if odd length
        if i < end {
            sum += UInt32(buffer[i]) << 8
        }

        // Fold 32-bit sum to 16 bits
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        // One's complement
        return ~UInt16(sum & 0xFFFF)
    }
}

public enum ICMPv6MessageType: UInt8, Sendable {
    case echoRequest = 128
    case echoReply = 129
    case routerSolicitation = 133
    case routerAdvertisement = 134
    case neighborSolicitation = 135
    case neighborAdvertisement = 136
}

public struct ICMPv6Header: Bindable {
    public static let size: Int = 4

    public var type: ICMPv6MessageType

    public var code: UInt8

    public init(type: ICMPv6MessageType = .echoReply, code: UInt8 = 0) {
        self.type = type
        self.code = code
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let offset = buffer.copyIn(as: UInt8.self, value: type.rawValue, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "ICMPv6Header", field: "type")
        }
        guard let offset = buffer.copyIn(as: UInt8.self, value: code, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "ICMPv6Header", field: "code")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: UInt16(0), offset: offset) else {
            throw BindError.sendMarshalFailure(type: "ICMPv6Header", field: "checksum")
        }

        assert(offset - startOffset == Self.size, "BUG: echo appendBuffer length mismatch - expected \(Self.size), got \(offset - startOffset)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "ICMPv6Header", field: "type")
        }
        guard let type = ICMPv6MessageType(rawValue: value) else {
            throw BindError.recvMarshalFailure(type: "ICMPv6Header", field: "type")
        }
        self.type = type

        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "ICMPv6Header", field: "code")
        }
        self.code = value

        let offsetSkippingChecksum = offset + MemoryLayout<UInt16>.size

        assert(offsetSkippingChecksum - startOffset == Self.size, "BUG: echo bindBuffer length mismatch - expected \(Self.size), got \(offsetSkippingChecksum - startOffset)")
        return offsetSkippingChecksum
    }
}

extension ICMPv4Header {
    public func matches(type: ICMPv4MessageType, code: UInt8 = 0) -> Bool {
        self.type == type && self.code == code
    }
}

extension ICMPv6Header {
    public func matches(type: ICMPv6MessageType, code: UInt8 = 0) -> Bool {
        self.type == type && self.code == code
    }
}
