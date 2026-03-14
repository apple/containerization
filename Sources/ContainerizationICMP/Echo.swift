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

public struct Echo: Bindable {
    public static let size = 4

    public var identifier: UInt16
    public var sequenceNumber: UInt16

    public init(
        identifier: UInt16,
        sequenceNumber: UInt16
    ) throws {
        self.identifier = identifier
        self.sequenceNumber = sequenceNumber
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let offset = buffer.copyIn(as: UInt16.self, value: identifier.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "Echo", field: "identifier")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: sequenceNumber.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "Echo", field: "sequenceNumber")
        }

        assert(offset - startOffset == Self.size, "BUG: echo appendBuffer length mismatch - expected \(Self.size), got \(offset - startOffset)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "Echo", field: "identifier")
        }
        identifier = UInt16(bigEndian: value)

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "Echo", field: "sequenceNumber")
        }
        sequenceNumber = UInt16(bigEndian: value)

        assert(offset - startOffset == Self.size, "BUG: echo bindBuffer length mismatch - expected \(Self.size), got \(offset - startOffset)")
        return offset
    }
}

package protocol EchoPayload {}

extension EchoPayload {
    public static var size: Int {
        56
    }
}

public struct EchoPayloadRTT: EchoPayload {
    public var date: Date

    public init(date: Date? = nil) {
        self.date = date ?? Date()
    }

    public func rtt(atDate: Date? = nil) -> TimeInterval {
        (atDate ?? Date()).timeIntervalSince(date)
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        let timeInterval = date.timeIntervalSinceReferenceDate
        guard let _ = buffer.copyIn(as: UInt64.self, value: timeInterval.bitPattern, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "EchoPayloadRTT", field: "date")
        }

        let finalOffset = offset + Self.size
        assert(finalOffset - startOffset == Self.size, "BUG: echo payload RTT appendBuffer length mismatch - expected \(Self.size), got \(finalOffset - startOffset)")
        return finalOffset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let (_, value) = buffer.copyOut(as: UInt64.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "EchoPayloadRTT", field: "date")
        }
        let timeInterval = Double(bitPattern: value)
        date = Date(timeIntervalSinceReferenceDate: timeInterval)

        let finalOffset = offset + Self.size
        assert(finalOffset - startOffset == Self.size, "BUG: echo payload RTT bindBuffer length mismatch - expected \(Self.size), got \(finalOffset - startOffset)")
        return finalOffset
    }
}
