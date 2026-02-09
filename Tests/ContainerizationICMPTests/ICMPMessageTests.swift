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

import Testing

@testable import ContainerizationICMP

// Tests based on RFC 792 (ICMPv4) and RFC 4443 (ICMPv6)
struct ICMPMessageTests {

    // MARK: - ICMPv4 Tests (RFC 792)

    @Test
    func testICMPv4HeaderRoundtrip() throws {
        let header = ICMPv4Header(type: .echoRequest, code: 0)

        var buffer = [UInt8](repeating: 0, count: ICMPv4Header.size)
        let bytesWritten = try header.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == ICMPv4Header.size)

        // Verify wire format
        // Type: 8 (Echo Request), Code: 0, Checksum: 0 (placeholder)
        #expect(buffer[0] == 8)
        #expect(buffer[1] == 0)
        #expect(buffer[2] == 0)
        #expect(buffer[3] == 0)

        var parsedHeader = ICMPv4Header()
        let bytesRead = try parsedHeader.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == ICMPv4Header.size)
        #expect(parsedHeader.type == .echoRequest)
        #expect(parsedHeader.code == 0)
    }

    @Test
    func testICMPv4Checksum() {
        // Example buffer: [Type, Code, Checksum, Checksum, ID, ID, Seq, Seq]
        // 8, 0, 0, 0, 1, 2, 3, 4
        // Words: 0x0800, 0x0000, 0x0102, 0x0304
        // Sum: 0x0800 + 0x0000 + 0x0102 + 0x0304 = 0x0C06
        // One's complement: ~0x0C06 = 0xF3F9

        let buffer: [UInt8] = [8, 0, 0, 0, 1, 2, 3, 4]
        let checksum = ICMPv4Header.checksum(buffer: buffer, offset: 0, length: buffer.count)

        #expect(checksum == 0xF3F9)
    }

    @Test
    func testICMPv4Match() {
        let header = ICMPv4Header(type: .destinationUnreachable, code: 3)

        #expect(header.matches(type: .destinationUnreachable, code: 3))
        #expect(!header.matches(type: .destinationUnreachable, code: 1))
        #expect(!header.matches(type: .echoReply, code: 3))
    }

    // MARK: - IPv6 Tests

    @Test
    func testICMPv6HeaderRoundtrip() throws {
        let header = ICMPv6Header(type: .echoRequest, code: 0)

        var buffer = [UInt8](repeating: 0, count: ICMPv6Header.size)
        let bytesWritten = try header.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == ICMPv6Header.size)

        // Verify wire format
        // Type: 128 (Echo Request), Code: 0, Checksum: 0 (placeholder)
        #expect(buffer[0] == 128)
        #expect(buffer[1] == 0)
        #expect(buffer[2] == 0)
        #expect(buffer[3] == 0)

        var parsedHeader = ICMPv6Header()
        let bytesRead = try parsedHeader.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == ICMPv6Header.size)
        #expect(parsedHeader.type == .echoRequest)
        #expect(parsedHeader.code == 0)
    }

    @Test
    func testICMPv6Match() {
        let header = ICMPv6Header(type: .neighborAdvertisement, code: 0)

        #expect(header.matches(type: .neighborAdvertisement, code: 0))
        #expect(!header.matches(type: .neighborSolicitation, code: 0))
    }

    // MARK: - Additional ICMPv4 Message Types (RFC 792)

    @Test
    func testICMPv4EchoReply() throws {
        // RFC 792: Type 0 - Echo Reply
        let header = ICMPv4Header(type: .echoReply, code: 0)

        var buffer = [UInt8](repeating: 0, count: ICMPv4Header.size)
        _ = try header.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 0)
        #expect(buffer[1] == 0)
    }

    @Test
    func testICMPv4DestinationUnreachable() throws {
        // RFC 792: Type 3 - Destination Unreachable, Code 3 - Port Unreachable
        let header = ICMPv4Header(type: .destinationUnreachable, code: 3)

        var buffer = [UInt8](repeating: 0, count: ICMPv4Header.size)
        _ = try header.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 3)
        #expect(buffer[1] == 3)

        var parsedHeader = ICMPv4Header()
        _ = try parsedHeader.bindBuffer(&buffer, offset: 0)

        #expect(parsedHeader.type == .destinationUnreachable)
        #expect(parsedHeader.code == 3)
    }

    @Test
    func testICMPv4TimeExceeded() throws {
        // RFC 792: Type 11 - Time Exceeded, Code 0 - TTL exceeded in transit
        let header = ICMPv4Header(type: .timeExceeded, code: 0)

        var buffer = [UInt8](repeating: 0, count: ICMPv4Header.size)
        _ = try header.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 11)
        #expect(buffer[1] == 0)
    }

    @Test
    func testICMPv4Redirect() throws {
        // RFC 792: Type 5 - Redirect, Code 1 - Redirect for Host
        let header = ICMPv4Header(type: .redirect, code: 1)

        var buffer = [UInt8](repeating: 0, count: ICMPv4Header.size)
        _ = try header.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 5)
        #expect(buffer[1] == 1)
    }

    // MARK: - Additional ICMPv6 Message Types (RFC 4443)

    @Test
    func testICMPv6EchoReply() throws {
        // RFC 4443: Type 129 - Echo Reply
        let header = ICMPv6Header(type: .echoReply, code: 0)

        var buffer = [UInt8](repeating: 0, count: ICMPv6Header.size)
        _ = try header.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 129)
        #expect(buffer[1] == 0)
    }

    @Test
    func testICMPv6RouterSolicitation() throws {
        // RFC 4861: Type 133 - Router Solicitation
        let header = ICMPv6Header(type: .routerSolicitation, code: 0)

        var buffer = [UInt8](repeating: 0, count: ICMPv6Header.size)
        _ = try header.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 133)
        #expect(buffer[1] == 0)

        var parsedHeader = ICMPv6Header()
        _ = try parsedHeader.bindBuffer(&buffer, offset: 0)

        #expect(parsedHeader.type == .routerSolicitation)
        #expect(parsedHeader.code == 0)
    }

    @Test
    func testICMPv6RouterAdvertisement() throws {
        // RFC 4861: Type 134 - Router Advertisement
        let header = ICMPv6Header(type: .routerAdvertisement, code: 0)

        var buffer = [UInt8](repeating: 0, count: ICMPv6Header.size)
        _ = try header.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 134)
        #expect(buffer[1] == 0)
    }

    @Test
    func testICMPv6NeighborSolicitation() throws {
        // RFC 4861: Type 135 - Neighbor Solicitation
        let header = ICMPv6Header(type: .neighborSolicitation, code: 0)

        var buffer = [UInt8](repeating: 0, count: ICMPv6Header.size)
        _ = try header.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 135)
        #expect(buffer[1] == 0)
    }

    @Test
    func testICMPv6NeighborAdvertisement() throws {
        // RFC 4861: Type 136 - Neighbor Advertisement
        let header = ICMPv6Header(type: .neighborAdvertisement, code: 0)

        var buffer = [UInt8](repeating: 0, count: ICMPv6Header.size)
        _ = try header.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 136)
        #expect(buffer[1] == 0)
    }

    // MARK: - Checksum Edge Cases

    @Test
    func testICMPv4ChecksumAllZeros() {
        // RFC 792: Checksum of all zeros
        let buffer: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
        let checksum = ICMPv4Header.checksum(buffer: buffer, offset: 0, length: buffer.count)

        #expect(checksum == 0xFFFF)
    }

    @Test
    func testICMPv4ChecksumOddLength() {
        // RFC 792: Checksum with odd length (last byte padded)
        // Buffer: [1, 2, 3] -> words: 0x0102, 0x0300
        // Sum: 0x0102 + 0x0300 = 0x0402
        // Complement: ~0x0402 = 0xFBFD
        let buffer: [UInt8] = [1, 2, 3]
        let checksum = ICMPv4Header.checksum(buffer: buffer, offset: 0, length: buffer.count)

        #expect(checksum == 0xFBFD)
    }

    @Test
    func testICMPv4ChecksumWithCarry() {
        // RFC 792: Test carry during checksum calculation
        // Words that will generate carries
        let buffer: [UInt8] = [0xFF, 0xFF, 0x00, 0x01]
        let checksum = ICMPv4Header.checksum(buffer: buffer, offset: 0, length: buffer.count)

        // 0xFFFF + 0x0001 = 0x10000 -> fold to 0x0000 + 0x0001 = 0x0001
        // Complement: ~0x0001 = 0xFFFE
        #expect(checksum == 0xFFFE)
    }
}
