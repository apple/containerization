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

//

import Foundation
import Testing

@testable import ContainerizationExtras

final class TestIPv4Address {
    @Test
    func testUintMask() {
        #expect(0xffff_ffff == PrefixLength(0).suffixMask32)
        #expect(0x0000_7fff == PrefixLength(17).suffixMask32)
        #expect(0x0000_0000 == PrefixLength(32).suffixMask32)
        #expect(0x0000_0000 == PrefixLength(33).suffixMask32)
        #expect(0x0000_0000 == PrefixLength(0).prefixMask32)
        #expect(0xfffe_0000 == PrefixLength(15).prefixMask32)
        #expect(0xffff_ffff == PrefixLength(32).prefixMask32)
        #expect(0xffff_ffff == PrefixLength(33).prefixMask32)
    }

    @Test
    func testOctetCountError() {
        let ipAddressValue = "192.168.64"
        do {
            _ = try IPv4Address(ipAddressValue)
            #expect(Bool(false), "Expected AddressError.invalidStringAddress to be thrown")
        } catch {
            #expect(
                error as? NetworkAddressError == .invalidStringAddress(address: ipAddressValue),
                "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testOctetInvalidError() {
        let ipAddressValue = "192.168.256.255"
        do {
            _ = try IPv4Address(ipAddressValue)
            #expect(Bool(false), "Expected AddressError.invalidStringAddress to be thrown")
        } catch {
            #expect(
                error as? NetworkAddressError == .invalidStringAddress(address: ipAddressValue),
                "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testAddressFromString() throws {
        let ipAddressValue = "192.168.64.25"
        let ipAddress = try IPv4Address(ipAddressValue)
        #expect(ipAddressValue == ipAddress.description)
        #expect(UInt32(0xc0a8_4019) == ipAddress.value)
        #expect([192, 168, 64, 25] == ipAddress.networkBytes)
    }

    @Test
    func testAddressPrefix() throws {
        let ipAddressValue = "172.18.204.85"
        let ipAddress = try IPv4Address(ipAddressValue)
        #expect(0x0000_0000 == ipAddress.prefix(prefixLength: 0).value)
        #expect(0xac12_cc55 == ipAddress.prefix(prefixLength: 32).value)
        #expect(0xac12_cc55 == ipAddress.prefix(prefixLength: 33).value)
        #expect(0xac10_0000 == ipAddress.prefix(prefixLength: 14).value)
    }

    @Test
    func testCoding() async throws {
        let text = "200.100.50.25"
        let expected = try IPv4Address(text)
        let data = try JSONEncoder().encode(expected)
        let actual = try JSONDecoder().decode(IPv4Address.self, from: data)
        #expect(expected == actual)
    }
}
