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

import ContainerizationExtras
import ContainerizationOS
import Testing

@testable import ContainerizationNetlink

struct NetlinkSessionTest {
    @Test func testNetworkLinkDown() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.pid = 0xc00c_c00c

        // Lookup interface by name, truncated response with no attributes (not needed at present).
        let expectedLookupRequest =
            "3400000012000100000000000cc00cc0"  // Netlink header (16 B)
            + "110000000000000001000000ffffffff"  // struct ifinfomsg (16 B)
            + "08001d00090000000c0003006574683000000000"  // RT attrs: IFLA_EXT_MASK + IFLA_IFNAME (“eth0”)
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "2000000010000000000000000cc00cc0"  // Netlink header (16 B)
                    + "00000100020000004310010000000000"  // struct ifinfomsg (16 B) – no RT attrs
            )
        )

        // Link‑down request – 32‑byte payload, no attributes.
        let expectedDownRequest =
            "2000000010000500000000000cc00cc0"  // Netlink header (16 B)
            + "110000000200000000000000ffffffff"  // struct ifinfomsg (16 B) – no RT attrs
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "2400000002000001000000000cc00cc0"  // Netlink header (16 B)
                    + "00000000200000001000050000000000"  // nlmsg_err payload (16 B)
                    + "0c000000"  // first 4 B of echoed header
            )
        )

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
            "340000001200010000000000c00cc00c"  // Netlink header (16 B)
            + "110000000000000001000000ffffffff"  // struct ifinfomsg (16 B)
            + "08001d00090000000c0003006574683000000000"  // RT attrs: IFLA_EXT_MASK + IFLA_IFNAME (“eth0”)
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "200000001000000000000000c00cc00c"  // Netlink header (16 B)
                    + "00000100020000004310010000000000"  // struct ifinfomsg (16 B) – no attributes
            )
        )

        // Network up for interface.
        let expectedUpRequest =
            "280000001000050000000000c00cc00c"  // Netlink header (16 B)
            + "110000000200000001000000ffffffff"  // struct ifinfomsg (16 B)
            + "0800040000050000"  // RT attr: IFLA_MTU = 1280 (8 B)
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "240000000200000100000000c00cc00c"  // Netlink header (16 B)
                    + "00000000200000001000050000000000"  // nlmsg_err payload (16 B)
                    + "11000000"  // 1st 4 B of echoed offending header
            )
        )

        let session = NetlinkSession(socket: mockSocket)
        try session.linkSet(interface: "eth0", up: true, mtu: 1280)

        #expect(mockSocket.requests.count == 2)
        #expect(mockSocket.responseIndex == 2)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())
        mockSocket.requests[1][8..<12] = [0, 0, 0, 0]
        #expect(expectedUpRequest == mockSocket.requests[1].hexEncodedString())
    }

    @Test func testNetworkLinkUpLoopback() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.pid = 0xc00c_c00c

        // Lookup loopback interface
        let expectedLookupRequest =
            "3000000012000100000000000cc00cc0"  // Netlink header (16 B)
            + "110000000000000001000000ffffffff"  // struct ifinfomsg (16 B)
            + "08001d0009000000080003006c6f0000"  // RT attrs: IFLA_EXT_MASK + IFLA_IFNAME (“lo”)
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "2000000010000000000000000cc00cc0"  // Netlink header (16 B)
                    + "00000100010000004310010000000000"  // struct ifinfomsg (16 B) – no attributes
            )
        )

        // Link up request for loopback, 32‑byte payload and no attributes
        let expectedUpRequest =
            "2000000010000500000000000cc00cc0"  // Netlink header (16 B)
            + "110000000100000001000000ffffffff"  // struct ifinfomsg (16 B) – no RT attrs
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "2400000002000001000000000cc00cc0"  // Netlink header (16 B)
                    + "00000000200000001000050000000000"  // nlmsg_err payload (16 B)
                    + "0c000000"  // first 4 B of echoed offending header
            )
        )

        let session = NetlinkSession(socket: mockSocket)
        try session.linkSet(interface: "lo", up: true)

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
            "34000000120001000000000078563412"  // Netlink header (16 B)
            + "110000000000000001000000ffffffff"  // struct ifinfomsg (16 B)
            + "08001d00090000000c0003006574683000000000"  // RT attrs: IFLA_EXT_MASK + IFLA_IFNAME (“eth0”)
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "48000000100000000000000078563412"  // Netlink header (16 B)
                    + "00000100020000004300010000000000"  // struct ifinfomsg (16 B)
                    + "090003006574683000000000"  // IFLA_IFNAME (“eth0”) attr (12 B)
                    + "08000d00e8030000"  // IFLA_MTU = 1000 attr (8 B)
                    + "0500100006000000"  // attr type 0x0010 (8 B)
                    + "0a000100825524c244030000"  // IFLA_ADDRESS = 82:55:24:c2:44:03 (12 B)
            )
        )

        let session = NetlinkSession(socket: mockSocket)
        let links = try session.linkGet(interface: "eth0")

        #expect(mockSocket.requests.count == 1)
        #expect(mockSocket.responseIndex == 1)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())
        try #require(links.count == 1)

        #expect(links[0].interfaceIndex == 2)
        #expect(links[0].interfaceFlags == 0x0001_0043)
        #expect(links[0].interfaceType == 1)
        #expect(links[0].isEthernet)
        #expect(!links[0].isLoopback)
        #expect(links[0].address == [0x82, 0x55, 0x24, 0xc2, 0x44, 0x03])
        try #require(links[0].attrDatas.count == 4)
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
        let expectedLookupRequest =
            "28000000120001030000000021436587"  // Netlink header (16 B)
            + "110000000000000001000000ffffffff"  // struct ifinfomsg (16 B)
            + "08001d0009000000"  // RT attr: IFLA_EXT_MASK (8 B)
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "28000000100002000000000021436587"  // Netlink header (16 B)
                    + "00000403010000004900010000000000"  // struct ifinfomsg (16 B)
                    + "070003006c6f0000"  // IFLA_IFNAME “lo” (8 B, padded)
            )
        )
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "2c000000100002000000000021436587"  // Netlink header (16 B)
                    + "00000003040000008000000000000000"  // struct ifinfomsg (16 B)
                    + "0a00030074756e6c30000000"  // IFLA_IFNAME “tunl0” attr (12 B, padded)
            )
        )
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "14000000030002000000000021436587"  // Netlink header (16 B) – NLMSG_DONE
                    + "00000000"  // 4-byte payload
            )
        )

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
            "3400000012000100000000000cc00cc0"  // Netlink header (16 B)
            + "110000000000000001000000ffffffff"  // struct ifinfomsg (16 B)
            + "08001d00090000000c0003006574683000000000"  // RT attrs: IFLA_EXT_MASK + IFLA_IFNAME (“eth0”)
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "2000000010000000000000000cc00cc0"  // Netlink header (16 B)
                    + "00000100020000004310010000000000"  // struct ifinfomsg (16 B) – no attributes
            )
        )

        // Network down for interface.
        let expectedAddRequest =
            "2800000014000506000000000cc00cc0"  // Netlink header (16 B)
            + "0218000002000000"  // ifaddrmsg (8 B): AF_INET, /24, ifindex 2
            + "08000200c0a840fa"  // RT attr: IFA_LOCAL    192.168.64.250
            + "08000100c0a840fa"  // RT attr: IFA_ADDRESS  192.168.64.250
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "2400000002000001000000000cc00cc0"  // Netlink header (16 B)
                    + "00000000280000001400050600000000"  // nlmsg_err payload (16 B)
                    + "1f000000"  // first 4 B of echoed offending header
            )
        )

        let session = NetlinkSession(socket: mockSocket)
        try session.addressAdd(interface: "eth0", ipv4Address: try CIDRv4("192.168.64.250/24"))

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
            "3400000012000100000000000cc00cc0"  // Netlink header (16 B)
            + "110000000000000001000000ffffffff"  // struct ifinfomsg (16 B)
            + "08001d00090000000c0003006574683000000000"  // RT attrs: IFLA_EXT_MASK + IFLA_IFNAME ("eth0")
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "2000000010000000000000000cc00cc0"  // Netlink header (16 B)
                    + "00000100020000004310010000000000"  // struct ifinfomsg (16 B) – no attributes
            )
        )

        // Add link route.
        let expectedAddRequest =
            "3400000018000506000000000cc00cc0"  // Netlink header (16 B)
            + "02180000fe02fd0100000000"  // struct rtmsg (12 B): AF_INET, dst/24,
            //   table=RT_TABLE_MAIN (0xfe), proto=RTPROT_BOOT (0x02),
            //   scope=RT_SCOPE_UNIVERSE (0xfd), type=RTN_UNICAST (0x01)
            + "08000100c0a84000"  // RTA_DST     192.168.64.0
            + "08000700c0a84003"  // RTA_PREFSRC 192.168.64.3
            + "0800040002000000"  // RTA_OIF     ifindex 2 (eth0)
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "2400000002000001000000000cc00cc0"  // Netlink header (16 B)
                    + "00000000280000001400050600000000"  // nlmsg_err payload (16 B)
                    + "1f000000"  // first 4 B of echoed offending header
            )
        )

        let session = NetlinkSession(socket: mockSocket)
        try session.routeAdd(
            interface: "eth0",
            dstIpv4Addr: try CIDRv4("192.168.64.0/24"),
            srcIpv4Addr: try IPv4Address("192.168.64.3")
        )

        #expect(mockSocket.requests.count == 2)
        #expect(mockSocket.responseIndex == 2)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())
        mockSocket.requests[1][8..<12] = [0, 0, 0, 0]
        #expect(expectedAddRequest == mockSocket.requests[1].hexEncodedString())
    }

    @Test func testNetworkLinkGetMultipleMessagesInSingleBuffer() throws {
        let mockSocket = try MockNetlinkSocket()
        mockSocket.pid = 0x8765_4321

        // Lookup all interfaces, with multiple messages packed into a single buffer.
        // This tests the fix for parsing multiple netlink messages that arrive in one recv() call.
        let expectedLookupRequest =
            "28000000120001030000000021436587"  // Netlink header (16 B)
            + "110000000000000001000000ffffffff"  // struct ifinfomsg (16 B)
            + "08001d0009000000"  // RT attr: IFLA_EXT_MASK (8 B)

        // Pack three messages into a single response buffer:
        //
        // Message 1: loopback interface with one attribute
        let msg1 =
            "28000000100002000000000021436587"  // Netlink header (16 B), len=40
            + "00000403010000004900010000000000"  // struct ifinfomsg (16 B)
            + "070003006c6f0000"  // IFLA_IFNAME "lo" (8 B, padded)

        // Message 2: tunl0 interface with one attribute
        let msg2 =
            "2c000000100002000000000021436587"  // Netlink header (16 B), len=44
            + "00000003040000008000000000000000"  // struct ifinfomsg (16 B)
            + "0a00030074756e6c30000000"  // IFLA_IFNAME "tunl0" attr (12 B, padded)

        // Message 3: eth0 interface with two attributes
        let msg3 =
            "34000000100002000000000021436587"  // Netlink header (16 B), len=52
            + "00000100020000004300010000000000"  // struct ifinfomsg (16 B)
            + "090003006574683000000000"  // IFLA_IFNAME "eth0" attr (12 B)
            + "08000d00e8030000"  // IFLA_MTU = 1000 attr (8 B)

        // Combine all three messages into a single buffer
        mockSocket.responses.append([UInt8](hex: msg1 + msg2 + msg3))

        // Final NLMSG_DONE message in separate buffer
        mockSocket.responses.append(
            [UInt8](
                hex:
                    "14000000030002000000000021436587"  // Netlink header (16 B) – NLMSG_DONE
                    + "00000000"  // 4-byte payload
            )
        )

        let session = NetlinkSession(socket: mockSocket)
        let links = try session.linkGet()

        #expect(mockSocket.requests.count == 1)
        #expect(mockSocket.responseIndex == 2)
        mockSocket.requests[0][8..<12] = [0, 0, 0, 0]
        #expect(expectedLookupRequest == mockSocket.requests[0].hexEncodedString())

        // Verify we got all three interfaces
        try #require(links.count == 3)

        // Verify loopback interface
        #expect(links[0].interfaceIndex == 1)
        try #require(links[0].attrDatas.count == 1)
        #expect(links[0].attrDatas[0].attribute.type == 0x0003)
        #expect(links[0].attrDatas[0].attribute.len == 0x0007)
        #expect(links[0].attrDatas[0].data == [0x6c, 0x6f, 0x00])

        // Verify tunl0 interface
        #expect(links[1].interfaceIndex == 4)
        try #require(links[1].attrDatas.count == 1)
        #expect(links[1].attrDatas[0].attribute.type == 0x0003)
        #expect(links[1].attrDatas[0].attribute.len == 0x000a)
        #expect(links[1].attrDatas[0].data == [0x74, 0x75, 0x6e, 0x6c, 0x30, 0x00])

        // Verify eth0 interface
        #expect(links[2].interfaceIndex == 2)
        try #require(links[2].attrDatas.count == 2)
        #expect(links[2].attrDatas[0].attribute.type == 0x0003)
        #expect(links[2].attrDatas[0].attribute.len == 0x0009)
        #expect(links[2].attrDatas[0].data == [0x65, 0x74, 0x68, 0x30, 0x00])
        #expect(links[2].attrDatas[1].attribute.type == 0x000d)
        #expect(links[2].attrDatas[1].attribute.len == 0x0008)
        #expect(links[2].attrDatas[1].data == [0xe8, 0x03, 0x00, 0x00])
    }
}

extension Array where Element == UInt8 {
    /// Initializes `[UInt8]` from an even-length hex string
    init(hex: String) {
        self = stride(from: 0, to: hex.count, by: 2).compactMap {
            UInt8(
                hex[hex.index(hex.startIndex, offsetBy: $0)...]
                    .prefix(2), radix: 16)
        }
    }
}
