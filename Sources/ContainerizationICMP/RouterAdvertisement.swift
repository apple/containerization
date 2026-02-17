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

public struct RouterAdvertisement: Bindable {
    public static let size = 12

    public var currentHopLimit: UInt8
    public var managedFlag: Bool
    public var otherFlag: Bool
    public var routerLifetime: UInt16
    public var reachableTime: UInt32
    public var retransTimer: UInt32

    public init(
        currentHopLimit: UInt8 = 0,
        managedFlag: Bool = false,
        otherFlag: Bool = false,
        routerLifetime: UInt16 = 0,
        reachableTime: UInt32 = 0,
        retransTimer: UInt32 = 0
    ) throws {
        self.currentHopLimit = currentHopLimit
        self.managedFlag = managedFlag
        self.otherFlag = otherFlag
        self.routerLifetime = routerLifetime
        self.reachableTime = reachableTime
        self.retransTimer = retransTimer
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let offset = buffer.copyIn(as: UInt8.self, value: currentHopLimit, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouterAdvertisement", field: "currentHopLimit")
        }
        let autoconfig = UInt8((managedFlag ? 0x80 : 0x00) | (otherFlag ? 0x40 : 0x00))
        guard let offset = buffer.copyIn(as: UInt8.self, value: autoconfig, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouterAdvertisement", field: "flags")
        }
        guard let offset = buffer.copyIn(as: UInt16.self, value: routerLifetime.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouterAdvertisement", field: "routerLifetime")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: reachableTime.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouterAdvertisement", field: "reachableTime")
        }
        guard let offset = buffer.copyIn(as: UInt32.self, value: retransTimer.bigEndian, offset: offset) else {
            throw BindError.sendMarshalFailure(type: "RouterAdvertisement", field: "retransTimer")
        }

        assert(offset - startOffset == Self.size, "BUG: router advertisement appendBuffer length mismatch - expected \(Self.size), got \(offset - startOffset)")
        return offset
    }

    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        guard let (offset, value) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouterAdvertisement", field: "currentHopLimit")
        }
        currentHopLimit = value

        guard let (offset, autoconfig) = buffer.copyOut(as: UInt8.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouterAdvertisement", field: "flags")
        }
        managedFlag = (autoconfig & 0x80) != 0
        otherFlag = (autoconfig & 0x40) != 0

        guard let (offset, value) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouterAdvertisement", field: "routerLifetime")
        }
        routerLifetime = UInt16(bigEndian: value)

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouterAdvertisement", field: "reachableTime")
        }
        reachableTime = UInt32(bigEndian: value)

        guard let (offset, value) = buffer.copyOut(as: UInt32.self, offset: offset) else {
            throw BindError.recvMarshalFailure(type: "RouterAdvertisement", field: "retransTimer")
        }
        retransTimer = UInt32(bigEndian: value)

        assert(offset - startOffset == Self.size, "BUG: router advertisement bindBuffer length mismatch - expected \(Self.size), got \(offset - startOffset)")
        return offset
    }
}
