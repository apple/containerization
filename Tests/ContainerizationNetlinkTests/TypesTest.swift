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

//

import Testing

@testable import ContainerizationNetlink

struct TypesTest {
    @Test func testNetlinkMessageHeader() throws {
        let expectedValue = NetlinkMessageHeader(
            len: 0x1234_5678, type: 0x9abc, flags: 0xdef0, seq: 0x1122_3344, pid: 0x5566_7788)
        let expectedBuffer: [UInt8] = [
            0x78, 0x56, 0x34, 0x12,
            0xbc, 0x9a, 0xf0, 0xde,
            0x44, 0x33, 0x22, 0x11,
            0x88, 0x77, 0x66, 0x55,
        ]
        var buffer = [UInt8](repeating: 0, count: NetlinkMessageHeader.size)
        let offset = try expectedValue.appendBuffer(&buffer, offset: 0)
        #expect(NetlinkMessageHeader.size == offset)
        #expect(expectedBuffer == buffer)
        guard let (offset, value) = buffer.copyOut(as: NetlinkMessageHeader.self) else {
            #expect(Bool(false), "could not bind value to buffer")
            return

        }

        #expect(offset == NetlinkMessageHeader.size)
        #expect(expectedValue == value)
    }

    @Test func testInterfaceInfo() throws {
        let expectedValue = InterfaceInfo(
            family: UInt8(AddressFamily.AF_NETLINK), type: 0x1234, index: 0x1234_5678, flags: 0x9abc_def0,
            change: 0x0fed_cba9
        )
        let expectedBuffer: [UInt8] = [
            0x10, 0x00, 0x34, 0x12,
            0x78, 0x56, 0x34, 0x12,
            0xf0, 0xde, 0xbc, 0x9a,
            0xa9, 0xcb, 0xed, 0x0f,
        ]
        var buffer = [UInt8](repeating: 0, count: InterfaceInfo.size)
        let offset = try expectedValue.appendBuffer(&buffer, offset: 0)
        #expect(InterfaceInfo.size == offset)
        #expect(expectedBuffer == buffer)
        guard let (offset, value) = buffer.copyOut(as: InterfaceInfo.self) else {
            #expect(Bool(false), "could not bind value to buffer")
            return

        }

        #expect(offset == InterfaceInfo.size)
        #expect(expectedValue == value)
    }

    @Test func testAddressInfo() throws {
        let expectedValue = AddressInfo(
            family: UInt8(AddressFamily.AF_INET), prefixLength: 24, flags: 0x5a, scope: 0xa5, index: 0xdead_beef)
        let expectedBuffer: [UInt8] = [
            0x02, 0x18, 0x5a, 0xa5,
            0xef, 0xbe, 0xad, 0xde,
        ]
        var buffer = [UInt8](repeating: 0, count: AddressInfo.size)
        let offset = try expectedValue.appendBuffer(&buffer, offset: 0)
        #expect(AddressInfo.size == offset)
        #expect(expectedBuffer == buffer)
        guard let (offset, value) = buffer.copyOut(as: AddressInfo.self) else {
            #expect(Bool(false), "could not bind value to buffer")
            return

        }

        #expect(offset == AddressInfo.size)
        #expect(expectedValue == value)
    }

    @Test func testRTAttribute() throws {
        let expectedValue = RTAttribute(len: 0x1234, type: 0x5678)
        let expectedBuffer: [UInt8] = [
            0x34, 0x12, 0x78, 0x56,
        ]
        var buffer = [UInt8](repeating: 0, count: RTAttribute.size)
        let offset = try expectedValue.appendBuffer(&buffer, offset: 0)
        #expect(RTAttribute.size == offset)
        #expect(expectedBuffer == buffer)
        guard let (offset, value) = buffer.copyOut(as: RTAttribute.self) else {
            #expect(Bool(false), "could not bind value to buffer")
            return

        }

        #expect(offset == RTAttribute.size)
        #expect(expectedValue == value)
    }
}
