//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

import ContainerizationOS
import Testing

@testable import ContainerizationNetlink

struct NetlinkSessionTest {
    @Test func testNetworkLinkDown() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.pid = 0xc00c_c00c

        // Lookup interface by name, truncated response with no attributes (not needed at present).
        let expectedLookupRequest =
            "3400000012000100000000000cc00cc0110000000000000001000000ffffffff08001d00090000000c0003006574683000000000"
        mockSocket.responses.append([
            0x20, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x0c, 0xc0, 0x0c, 0xc0,
            0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00,
            0x43, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])

        // Network down for interface.
        let expectedDownRequest = "2800000010000500000000000cc00cc0110000000200000000000000ffffffff0800040000050000"
        mockSocket.responses.append([
            0x24, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x0c, 0xc0, 0x0c, 0xc0,
            0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
            0x10, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x0c, 0x00, 0x00, 0x00,
        ])

        let session = NetlinkSession(socket: mockSocket)
        try session.linkSet(interface: "eth0", up: false)

        #expect(mockSocket.requests.count == 2)
        #expect(mockSocket.responseIndex == 2)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())
        mockSocket.requests[1][8..<12] = [0, 0, 0, 0]
        #expect(expectedDownRequest == mockSocket.requests[1].hexEncodedString())
    }

    @Test func testNetworkLinkUp() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.pid = 0x0cc0_0cc0

        // Lookup interface by name, truncated response with no attributes (not needed at present).
        let expectedLookupRequest =
            "340000001200010000000000c00cc00c110000000000000001000000ffffffff08001d00090000000c0003006574683000000000"
        mockSocket.responses.append([
            0x20, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0xc0, 0x0c, 0xc0, 0x0c,
            0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00,
            0x43, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])

        // Network up for interface.
        let expectedUpRequest = "280000001000050000000000c00cc00c110000000200000001000000ffffffff0800040000050000"
        mockSocket.responses.append([
            0x24, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0xc0, 0x0c, 0xc0, 0x0c,
            0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
            0x10, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x11, 0x00, 0x00, 0x00,
        ])

        let session = NetlinkSession(socket: mockSocket)
        try session.linkSet(interface: "eth0", up: true)

        #expect(mockSocket.requests.count == 2)
        #expect(mockSocket.responseIndex == 2)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())
        mockSocket.requests[1][8..<12] = [0, 0, 0, 0]
        #expect(expectedUpRequest == mockSocket.requests[1].hexEncodedString())
    }

    @Test func testNetworkLinkGetEth0() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.pid = 0x1234_5678

        // Lookup interface by name, truncated response with three attributes.
        let expectedLookupRequest =
            "34000000120001000000000078563412110000000000000001000000ffffffff08001d00090000000c0003006574683000000000"
        mockSocket.responses.append([
            0x3c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x78, 0x56, 0x34, 0x12,
            0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00,
            0x43, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x09, 0x00, 0x03, 0x00, 0x65, 0x74, 0x68, 0x30,
            0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x0d, 0x00,
            0xe8, 0x03, 0x00, 0x00, 0x05, 0x00, 0x10, 0x00,
            0x06, 0x00, 0x00, 0x00,
        ])

        let session = NetlinkSession(socket: mockSocket)
        let links = try session.linkGet(interface: "eth0")

        #expect(mockSocket.requests.count == 1)
        #expect(mockSocket.responseIndex == 1)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())
        try #require(links.count == 1)

        #expect(links[0].interfaceIndex == 2)
        try #require(links[0].attrDatas.count == 3)
        #expect(links[0].attrDatas[0].attribute.type == 0x0003)
        #expect(links[0].attrDatas[0].attribute.len == 0x0009)
        #expect(links[0].attrDatas[0].data == [0x65, 0x74, 0x68, 0x30, 0x00])
        #expect(links[0].attrDatas[1].attribute.type == 0x000d)
        #expect(links[0].attrDatas[1].attribute.len == 0x0008)
        #expect(links[0].attrDatas[1].data == [0xe8, 0x03, 0x00, 0x00])
        #expect(links[0].attrDatas[2].attribute.type == 0x0010)
        #expect(links[0].attrDatas[2].attribute.len == 0x0005)
        #expect(links[0].attrDatas[2].data == [0x06])
    }

    @Test func testNetworkLinkGet() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.pid = 0x8765_4321

        // Lookup all interfaces, responses with only the interface name attribute.
        let expectedLookupRequest = "28000000120001030000000021436587110000000000000001000000ffffffff08001d0009000000"
        mockSocket.responses.append([
            0x28, 0x00, 0x00, 0x00, 0x10, 0x00, 0x02, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x21, 0x43, 0x65, 0x87,
            0x00, 0x00, 0x04, 0x03, 0x01, 0x00, 0x00, 0x00,
            0x49, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x07, 0x00, 0x03, 0x00, 0x6c, 0x6f, 0x00, 0x00,
        ])
        mockSocket.responses.append([
            0x2c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x02, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x21, 0x43, 0x65, 0x87,
            0x00, 0x00, 0x00, 0x03, 0x04, 0x00, 0x00, 0x00,
            0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x0a, 0x00, 0x03, 0x00, 0x74, 0x75, 0x6e, 0x6c,
            0x30, 0x00, 0x00, 0x00,
        ])
        mockSocket.responses.append([
            0x14, 0x00, 0x00, 0x00, 0x03, 0x00, 0x02, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x21, 0x43, 0x65, 0x87,
            0x00, 0x00, 0x00, 0x00,
        ])

        let session = NetlinkSession(socket: mockSocket)
        let links = try session.linkGet()

        #expect(mockSocket.requests.count == 1)
        #expect(mockSocket.responseIndex == 3)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())
        try #require(links.count == 2)

        #expect(links[0].interfaceIndex == 1)
        try #require(links[0].attrDatas.count == 1)
        #expect(links[0].attrDatas[0].attribute.type == 0x0003)
        #expect(links[0].attrDatas[0].attribute.len == 0x0007)
        #expect(links[0].attrDatas[0].data == [0x6c, 0x6f, 0x00])

        #expect(links[1].interfaceIndex == 4)
        try #require(links[1].attrDatas.count == 1)
        #expect(links[1].attrDatas[0].attribute.type == 0x0003)
        #expect(links[1].attrDatas[0].attribute.len == 0x000a)
        #expect(links[1].attrDatas[0].data == [0x74, 0x75, 0x6e, 0x6c, 0x30, 0x00])
    }

    @Test func testNetworkAddressAdd() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.pid = 0xc00c_c00c

        // Lookup interface by name, truncated response with no attributes (not needed at present).
        let expectedLookupRequest =
            "3400000012000100000000000cc00cc0110000000000000001000000ffffffff08001d00090000000c0003006574683000000000"
        mockSocket.responses.append([
            0x20, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x0c, 0xc0, 0x0c, 0xc0,
            0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00,
            0x43, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])

        // Network down for interface.
        let expectedAddRequest = "2800000014000506000000000cc00cc0021800000200000008000200c0a840fa08000100c0a840fa"
        mockSocket.responses.append([
            0x24, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x0c, 0xc0, 0x0c, 0xc0,
            0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00,
            0x14, 0x00, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00,
            0x1f, 0x00, 0x00, 0x00,
        ])

        let session = NetlinkSession(socket: mockSocket)
        try session.addressAdd(interface: "eth0", address: "192.168.64.250/24")

        #expect(mockSocket.requests.count == 2)
        #expect(mockSocket.responseIndex == 2)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())
        #expect(expectedAddRequest == mockSocket.requests[1].hexEncodedString())
    }

    @Test func testNetworkRouteAddIpLink() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.pid = 0xc00c_c00c

        // Lookup interface by name, truncated response with no attributes (not needed at present).
        let expectedLookupRequest =
            "3400000012000100000000000cc00cc0110000000000000001000000ffffffff08001d00090000000c0003006574683000000000"
        mockSocket.responses.append([
            0x20, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x0c, 0xc0, 0x0c, 0xc0,
            0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00,
            0x43, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])

        // Add link route.
        let expectedAddRequest =
            "3400000018000506000000000cc00cc002180000fe02fd010000000008000100c0a8400008000700c0a840030800040002000000"
        mockSocket.responses.append([
            0x24, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x0c, 0xc0, 0x0c, 0xc0,
            0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00,
            0x14, 0x00, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00,
            0x1f, 0x00, 0x00, 0x00,
        ])

        let session = NetlinkSession(socket: mockSocket)
        try session.routeAdd(
            interface: "eth0",
            destinationAddress: "192.168.64.0/24",
            srcAddr: "192.168.64.3"
        )

        #expect(mockSocket.requests.count == 2)
        #expect(mockSocket.responseIndex == 2)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())
        mockSocket.requests[1][8..<12] = [0, 0, 0, 0]
        #expect(expectedAddRequest == mockSocket.requests[1].hexEncodedString())
    }
}
