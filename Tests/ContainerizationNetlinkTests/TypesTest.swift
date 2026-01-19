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

    @Test func testSockaddrNetlink() throws {
        let expectedValue = SockaddrNetlink(family: 16, pid: 0x1234_5678, groups: 0x9abc_def0)
        let expectedBuffer: [UInt8] = [
            0x10, 0x00, 0x00, 0x00,
            0x78, 0x56, 0x34, 0x12,
            0xf0, 0xde, 0xbc, 0x9a,
        ]
        var buffer = [UInt8](repeating: 0, count: SockaddrNetlink.size)
        let offset = try expectedValue.appendBuffer(&buffer, offset: 0)
        #expect(SockaddrNetlink.size == offset)
        #expect(expectedBuffer == buffer)

        var unmarshaledValue = SockaddrNetlink()
        let bindOffset = try unmarshaledValue.bindBuffer(&buffer, offset: 0)
        #expect(bindOffset == SockaddrNetlink.size)
        #expect(expectedValue == unmarshaledValue)
    }

    @Test func testRouteInfo() throws {
        let expectedValue = RouteInfo(
            family: UInt8(AddressFamily.AF_INET),
            dstLen: 24,
            srcLen: 0,
            tos: 0,
            table: RouteTable.MAIN,
            proto: RouteProtocol.KERNEL,
            scope: RouteScope.LINK,
            type: RouteType.UNICAST,
            flags: 0xdead_beef
        )
        let expectedBuffer: [UInt8] = [
            0x02, 0x18, 0x00, 0x00,
            0xfe, 0x02, 0xfd, 0x01,
            0xef, 0xbe, 0xad, 0xde,
        ]
        var buffer = [UInt8](repeating: 0, count: RouteInfo.size)
        let offset = try expectedValue.appendBuffer(&buffer, offset: 0)
        #expect(RouteInfo.size == offset)
        #expect(expectedBuffer == buffer)

        var unmarshaledValue = RouteInfo(
            dstLen: 0, srcLen: 0, tos: 0, table: 0, proto: 0, scope: 0, type: 0, flags: 0)
        let bindOffset = try unmarshaledValue.bindBuffer(&buffer, offset: 0)
        #expect(bindOffset == RouteInfo.size)
        #expect(expectedValue == unmarshaledValue)
    }

    @Test func testLinkStatistics64() throws {
        var expectedValue = LinkStatistics64()
        expectedValue.rxPackets = 0x0102_0304_0506_0708
        expectedValue.txPackets = 0x090a_0b0c_0d0e_0f10
        expectedValue.rxBytes = 0x1112_1314_1516_1718
        expectedValue.txBytes = 0x191a_1b1c_1d1e_1f20
        expectedValue.rxErrors = 0x2122_2324_2526_2728
        expectedValue.txErrors = 0x292a_2b2c_2d2e_2f30
        expectedValue.rxDropped = 0x3132_3334_3536_3738
        expectedValue.txDropped = 0x393a_3b3c_3d3e_3f40
        expectedValue.multicast = 0x4142_4344_4546_4748
        expectedValue.collisions = 0x494a_4b4c_4d4e_4f50
        expectedValue.rxLengthErrors = 0x5152_5354_5556_5758
        expectedValue.rxOverErrors = 0x595a_5b5c_5d5e_5f60
        expectedValue.rxCrcErrors = 0x6162_6364_6566_6768
        expectedValue.rxFrameErrors = 0x696a_6b6c_6d6e_6f70
        expectedValue.rxFifoErrors = 0x7172_7374_7576_7778
        expectedValue.rxMissedErrors = 0x797a_7b7c_7d7e_7f80
        expectedValue.txAbortedErrors = 0x8182_8384_8586_8788
        expectedValue.txCarrierErrors = 0x898a_8b8c_8d8e_8f90
        expectedValue.txFifoErrors = 0x9192_9394_9596_9798
        expectedValue.txHeartbeatErrors = 0x999a_9b9c_9d9e_9fa0
        expectedValue.txWindowErrors = 0xa1a2_a3a4_a5a6_a7a8
        expectedValue.rxCompressed = 0xa9aa_abac_adae_afb0
        expectedValue.txCompressed = 0xb1b2_b3b4_b5b6_b7b8

        let expectedBuffer: [UInt8] = [
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            0x10, 0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09,
            0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
            0x20, 0x1f, 0x1e, 0x1d, 0x1c, 0x1b, 0x1a, 0x19,
            0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21,
            0x30, 0x2f, 0x2e, 0x2d, 0x2c, 0x2b, 0x2a, 0x29,
            0x38, 0x37, 0x36, 0x35, 0x34, 0x33, 0x32, 0x31,
            0x40, 0x3f, 0x3e, 0x3d, 0x3c, 0x3b, 0x3a, 0x39,
            0x48, 0x47, 0x46, 0x45, 0x44, 0x43, 0x42, 0x41,
            0x50, 0x4f, 0x4e, 0x4d, 0x4c, 0x4b, 0x4a, 0x49,
            0x58, 0x57, 0x56, 0x55, 0x54, 0x53, 0x52, 0x51,
            0x60, 0x5f, 0x5e, 0x5d, 0x5c, 0x5b, 0x5a, 0x59,
            0x68, 0x67, 0x66, 0x65, 0x64, 0x63, 0x62, 0x61,
            0x70, 0x6f, 0x6e, 0x6d, 0x6c, 0x6b, 0x6a, 0x69,
            0x78, 0x77, 0x76, 0x75, 0x74, 0x73, 0x72, 0x71,
            0x80, 0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x7a, 0x79,
            0x88, 0x87, 0x86, 0x85, 0x84, 0x83, 0x82, 0x81,
            0x90, 0x8f, 0x8e, 0x8d, 0x8c, 0x8b, 0x8a, 0x89,
            0x98, 0x97, 0x96, 0x95, 0x94, 0x93, 0x92, 0x91,
            0xa0, 0x9f, 0x9e, 0x9d, 0x9c, 0x9b, 0x9a, 0x99,
            0xa8, 0xa7, 0xa6, 0xa5, 0xa4, 0xa3, 0xa2, 0xa1,
            0xb0, 0xaf, 0xae, 0xad, 0xac, 0xab, 0xaa, 0xa9,
            0xb8, 0xb7, 0xb6, 0xb5, 0xb4, 0xb3, 0xb2, 0xb1,
        ]

        var buffer = [UInt8](repeating: 0, count: LinkStatistics64.size)
        let offset = try expectedValue.appendBuffer(&buffer, offset: 0)
        #expect(LinkStatistics64.size == offset)
        #expect(expectedBuffer == buffer)

        var unmarshaledValue = LinkStatistics64()
        let bindOffset = try unmarshaledValue.bindBuffer(&buffer, offset: 0)
        #expect(bindOffset == LinkStatistics64.size)
        #expect(expectedValue == unmarshaledValue)
    }
}
