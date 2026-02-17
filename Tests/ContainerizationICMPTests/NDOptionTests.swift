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
import Testing

@testable import ContainerizationICMP

// Tests based on RFC 4861 Section 4.6 - Neighbor Discovery Options
struct NDOptionTests {

    // MARK: - Option Header Tests (RFC 4861 Section 4.6)

    @Test
    func testNDOptionHeaderRoundtrip() throws {
        // RFC 4861: All options have Type and Length fields
        let header = NDOptionHeader(type: .sourceLinkLayerAddress, lengthInUnits: 1)

        var buffer = [UInt8](repeating: 0, count: NDOptionHeader.size)
        let bytesWritten = try header.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == NDOptionHeader.size)
        #expect(NDOptionHeader.size == 2)

        // Verify wire format
        // Type: 1 (Source Link-layer Address)
        #expect(buffer[0] == 1)
        // Length: 1 (in units of 8 octets)
        #expect(buffer[1] == 1)

        var parsedHeader = NDOptionHeader(type: .sourceLinkLayerAddress, lengthInUnits: 0)
        let bytesRead = try parsedHeader.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == NDOptionHeader.size)
        #expect(parsedHeader.type == .sourceLinkLayerAddress)
        #expect(parsedHeader.lengthInUnits == 1)
    }

    // MARK: - Source Link-Layer Address Option (RFC 4861 Section 4.6.1)

    @Test
    func testSourceLinkLayerAddressRoundtrip() throws {
        // RFC 4861 Section 4.6.1: Ethernet address is 6 octets
        let macAddress = try MACAddress([0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
        let option = SourceLinkLayerAddress(address: macAddress)

        var buffer = [UInt8](repeating: 0, count: SourceLinkLayerAddress.size)
        let bytesWritten = try option.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == SourceLinkLayerAddress.size)
        #expect(SourceLinkLayerAddress.size == 6)

        // Verify wire format - MAC address bytes
        #expect(buffer[0] == 0x00)
        #expect(buffer[1] == 0x11)
        #expect(buffer[2] == 0x22)
        #expect(buffer[3] == 0x33)
        #expect(buffer[4] == 0x44)
        #expect(buffer[5] == 0x55)

        var parsedOption = SourceLinkLayerAddress(address: MACAddress(0))
        let bytesRead = try parsedOption.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == SourceLinkLayerAddress.size)
        #expect(parsedOption.address.bytes == macAddress.bytes)
    }

    @Test
    func testSourceLinkLayerAddressOptionEnum() throws {
        // RFC 4861: Complete option including header
        let macAddress = try MACAddress([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        let option = NDOption.sourceLinkLayerAddress(macAddress)

        #expect(option.type == .sourceLinkLayerAddress)
        #expect(option.lengthInUnits == 1)  // 8 bytes total: 2 (header) + 6 (MAC)

        var buffer = [UInt8](repeating: 0, count: 8)
        let bytesWritten = try option.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == 8)

        // Verify complete option format
        #expect(buffer[0] == 1)  // Type
        #expect(buffer[1] == 1)  // Length
        #expect(buffer[2] == 0xAA)  // MAC byte 0
        #expect(buffer[3] == 0xBB)  // MAC byte 1
        #expect(buffer[4] == 0xCC)  // MAC byte 2
        #expect(buffer[5] == 0xDD)  // MAC byte 3
        #expect(buffer[6] == 0xEE)  // MAC byte 4
        #expect(buffer[7] == 0xFF)  // MAC byte 5
    }

    // MARK: - Prefix Information Option (RFC 4861 Section 4.6.2)

    @Test
    func testPrefixInformationRoundtrip() throws {
        // RFC 4861 Section 4.6.2: Prefix Information for SLAAC
        let prefix = try IPv6Address([
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        let prefixInfo = PrefixInformation(
            prefixLength: 64,
            onLinkFlag: true,
            autonomousFlag: true,
            validLifetime: 2_592_000,  // 30 days
            preferredLifetime: 604800,  // 7 days
            prefix: prefix
        )

        var buffer = [UInt8](repeating: 0, count: PrefixInformation.size)
        let bytesWritten = try prefixInfo.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == PrefixInformation.size)
        #expect(PrefixInformation.size == 30)

        // Verify wire format per RFC 4861 Section 4.6.2
        // Byte 0: Prefix Length
        #expect(buffer[0] == 64)

        // Byte 1: Flags (L=1, A=1 -> 0xC0)
        #expect(buffer[1] == 0xC0)

        // Bytes 2-5: Valid Lifetime (2592000 = 0x00278D00)
        #expect(buffer[2] == 0x00)
        #expect(buffer[3] == 0x27)
        #expect(buffer[4] == 0x8D)
        #expect(buffer[5] == 0x00)

        // Bytes 6-9: Preferred Lifetime (604800 = 0x00093A80)
        #expect(buffer[6] == 0x00)
        #expect(buffer[7] == 0x09)
        #expect(buffer[8] == 0x3A)
        #expect(buffer[9] == 0x80)

        // Bytes 10-13: Reserved2 (must be zero)
        #expect(buffer[10] == 0x00)
        #expect(buffer[11] == 0x00)
        #expect(buffer[12] == 0x00)
        #expect(buffer[13] == 0x00)

        // Bytes 14-29: Prefix (2001:db8::)
        #expect(buffer[14] == 0x20)
        #expect(buffer[15] == 0x01)
        #expect(buffer[16] == 0x0d)
        #expect(buffer[17] == 0xb8)

        var parsedInfo = PrefixInformation(
            prefixLength: 0, onLinkFlag: false, autonomousFlag: false,
            validLifetime: 0, preferredLifetime: 0, prefix: IPv6Address(0)
        )
        let bytesRead = try parsedInfo.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == PrefixInformation.size)
        #expect(parsedInfo.prefixLength == 64)
        #expect(parsedInfo.onLinkFlag == true)
        #expect(parsedInfo.autonomousFlag == true)
        #expect(parsedInfo.validLifetime == 2_592_000)
        #expect(parsedInfo.preferredLifetime == 604800)
        #expect(parsedInfo.prefix.bytes == prefix.bytes)
    }

    @Test
    func testPrefixInformationOnLinkOnly() throws {
        // RFC 4861: On-link prefix without SLAAC (L=1, A=0)
        let prefix = try IPv6Address([
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        let prefixInfo = PrefixInformation(
            prefixLength: 64,
            onLinkFlag: true,
            autonomousFlag: false,
            validLifetime: 0xFFFF_FFFF,
            preferredLifetime: 0xFFFF_FFFF,
            prefix: prefix
        )

        var buffer = [UInt8](repeating: 0, count: PrefixInformation.size)
        _ = try prefixInfo.appendBuffer(&buffer, offset: 0)

        // L=1, A=0 -> 0x80
        #expect(buffer[1] == 0x80)

        var parsedInfo = PrefixInformation(
            prefixLength: 0, onLinkFlag: false, autonomousFlag: false,
            validLifetime: 0, preferredLifetime: 0, prefix: IPv6Address(0)
        )
        _ = try parsedInfo.bindBuffer(&buffer, offset: 0)

        #expect(parsedInfo.onLinkFlag == true)
        #expect(parsedInfo.autonomousFlag == false)
    }

    @Test
    func testPrefixInformationOptionEnum() throws {
        // RFC 4861: Complete prefix information option
        let prefix = try IPv6Address([
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        let prefixInfo = PrefixInformation(
            prefixLength: 64,
            onLinkFlag: true,
            autonomousFlag: true,
            validLifetime: 86400,
            preferredLifetime: 43200,
            prefix: prefix
        )
        let option = NDOption.prefixInformation(prefixInfo)

        #expect(option.type == .prefixInformation)
        #expect(option.lengthInUnits == 4)  // 32 bytes: 2 (header) + 30 (data)

        var buffer = [UInt8](repeating: 0, count: 32)
        let bytesWritten = try option.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == 32)
        #expect(buffer[0] == 3)  // Type: Prefix Information
        #expect(buffer[1] == 4)  // Length: 4 units
    }

    // MARK: - MTU Option (RFC 4861 Section 4.6.4)

    @Test
    func testMTUOptionRoundtrip() throws {
        // RFC 4861 Section 4.6.4: MTU option for link MTU
        let mtuOption = MTUOption(mtu: 1500)

        var buffer = [UInt8](repeating: 0, count: MTUOption.size)
        let bytesWritten = try mtuOption.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == MTUOption.size)
        #expect(MTUOption.size == 6)

        // Verify wire format
        // Bytes 0-1: Reserved (must be zero)
        #expect(buffer[0] == 0x00)
        #expect(buffer[1] == 0x00)

        // Bytes 2-5: MTU (1500 = 0x000005DC)
        #expect(buffer[2] == 0x00)
        #expect(buffer[3] == 0x00)
        #expect(buffer[4] == 0x05)
        #expect(buffer[5] == 0xDC)

        var parsedOption = MTUOption(mtu: 0)
        let bytesRead = try parsedOption.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == MTUOption.size)
        #expect(parsedOption.mtu == 1500)
    }

    @Test
    func testMTUOptionEnum() throws {
        // RFC 4861: Complete MTU option
        let option = NDOption.mtu(9000)  // Jumbo frames

        #expect(option.type == .mtu)
        #expect(option.lengthInUnits == 1)  // 8 bytes: 2 (header) + 6 (data)

        var buffer = [UInt8](repeating: 0, count: 8)
        let bytesWritten = try option.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == 8)
        #expect(buffer[0] == 5)  // Type: MTU
        #expect(buffer[1] == 1)  // Length: 1 unit

        // MTU value 9000 = 0x00002328
        #expect(buffer[4] == 0x00)
        #expect(buffer[5] == 0x00)
        #expect(buffer[6] == 0x23)
        #expect(buffer[7] == 0x28)
    }

    // MARK: - Recursive DNS Server Option (RFC 8106 Section 5.1)

    @Test
    func testRecursiveDNSServerRoundtrip() throws {
        // RFC 8106: RDNSS option header (without addresses)
        let rdnss = RecursiveDNSServer(lifetime: 3600)

        var buffer = [UInt8](repeating: 0, count: RecursiveDNSServer.size)
        let bytesWritten = try rdnss.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == RecursiveDNSServer.size)
        #expect(RecursiveDNSServer.size == 6)

        // Verify wire format
        // Bytes 0-1: Reserved (must be zero)
        #expect(buffer[0] == 0x00)
        #expect(buffer[1] == 0x00)

        // Bytes 2-5: Lifetime (3600 = 0x00000E10)
        #expect(buffer[2] == 0x00)
        #expect(buffer[3] == 0x00)
        #expect(buffer[4] == 0x0E)
        #expect(buffer[5] == 0x10)

        var parsedRDNSS = RecursiveDNSServer(lifetime: 0)
        let bytesRead = try parsedRDNSS.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == RecursiveDNSServer.size)
        #expect(parsedRDNSS.lifetime == 3600)
    }

    @Test
    func testRecursiveDNSServerOptionWithSingleAddress() throws {
        // RFC 8106: RDNSS with one DNS server
        let dnsServer = try IPv6Address([
            0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x88, 0x88,
        ])
        let option = NDOption.recursiveDNSServer(lifetime: 7200, addresses: [dnsServer])

        #expect(option.type == .recursiveDNSServer)
        // 24 bytes total: 2 (header) + 6 (RDNSS) + 16 (1 address) = 24 bytes = 3 units
        #expect(option.lengthInUnits == 3)

        var buffer = [UInt8](repeating: 0, count: 24)
        let bytesWritten = try option.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == 24)
        #expect(buffer[0] == 25)  // Type: RDNSS
        #expect(buffer[1] == 3)  // Length: 3 units

        // Lifetime 7200 = 0x00001C20
        #expect(buffer[4] == 0x00)
        #expect(buffer[5] == 0x00)
        #expect(buffer[6] == 0x1C)
        #expect(buffer[7] == 0x20)

        // First address starts at byte 8
        #expect(buffer[8] == 0x20)
        #expect(buffer[9] == 0x01)
        #expect(buffer[10] == 0x48)
        #expect(buffer[11] == 0x60)
    }

    @Test
    func testRecursiveDNSServerOptionWithMultipleAddresses() throws {
        // RFC 8106: RDNSS with two DNS servers
        let dns1 = try IPv6Address([
            0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x88, 0x88,
        ])
        let dns2 = try IPv6Address([
            0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x88, 0x44,
        ])
        let option = NDOption.recursiveDNSServer(lifetime: 3600, addresses: [dns1, dns2])

        // 40 bytes total: 2 (header) + 6 (RDNSS) + 32 (2 addresses) = 40 bytes = 5 units
        #expect(option.lengthInUnits == 5)

        var buffer = [UInt8](repeating: 0, count: 40)
        let bytesWritten = try option.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == 40)
        #expect(buffer[0] == 25)  // Type: RDNSS
        #expect(buffer[1] == 5)  // Length: 5 units
    }

    // MARK: - IPv6 Address Option Data

    @Test
    func testIPv6AddressOptionDataRoundtrip() throws {
        let address = try IPv6Address([
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x02, 0x11, 0x22, 0xff, 0xfe, 0x33, 0x44, 0x55,
        ])
        let addrData = IPv6AddressOptionData(address: address)

        var buffer = [UInt8](repeating: 0, count: IPv6AddressOptionData.size)
        let bytesWritten = try addrData.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == IPv6AddressOptionData.size)
        #expect(IPv6AddressOptionData.size == 16)

        // Verify all 16 bytes
        #expect(buffer[0] == 0xfe)
        #expect(buffer[1] == 0x80)
        #expect(buffer[8] == 0x02)
        #expect(buffer[15] == 0x55)

        var parsedAddr = IPv6AddressOptionData(address: IPv6Address(0))
        let bytesRead = try parsedAddr.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == IPv6AddressOptionData.size)
        #expect(parsedAddr.address.bytes == address.bytes)
    }
}
