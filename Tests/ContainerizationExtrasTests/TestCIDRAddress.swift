//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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
// swiftlint:disable force_try
//

import Foundation
import Testing

@testable import ContainerizationExtras

final class TestCIDRAddress {
    @Test
    func testMissingSplitError() {
        let cidr = "192.168.64.0"
        do {
            _ = try CIDRAddress(cidr)
            #expect(Bool(false), "Expected AddressError.invalidCIDR to be thrown")
        } catch {
            #expect(error as? NetworkAddressError == .invalidCIDR(cidr: cidr), "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testInvalidIPError() {
        let cidr = "192.168.256.1/24"
        do {
            _ = try CIDRAddress(cidr)
            #expect(Bool(false), "Expected AddressError.invalidCIDR to be thrown")
        } catch {
            #expect(
                error as? NetworkAddressError == .invalidStringAddress(address: "192.168.256.1"),
                "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testInvalidSubnetTypeError() {
        let cidr = "192.168.64.0/foo"
        do {
            _ = try CIDRAddress(cidr)
            #expect(Bool(false), "Expected AddressError.invalidCIDR to be thrown")
        } catch {
            #expect(error as? NetworkAddressError == .invalidCIDR(cidr: cidr), "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testInvalidPrefixTooLargeError() {
        let cidr = "192.168.64.0/33"
        do {
            _ = try CIDRAddress(cidr)
            #expect(Bool(false), "Expected AddressError.invalidCIDR to be thrown")
        } catch {
            #expect(error as? NetworkAddressError == .invalidCIDR(cidr: cidr), "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testInvalidPrefixTooSmallError() {
        let cidr = "192.168.64.0/-1"
        do {
            _ = try CIDRAddress(cidr)
            #expect(Bool(false), "Expected AddressError.invalidCIDR to be thrown")
        } catch {
            #expect(error as? NetworkAddressError == .invalidCIDR(cidr: cidr), "Unexpected error thrown: \(error)")
        }
    }

    @Test
    func testComparison() async throws {
        let cidr64_1 = try! CIDRAddress("192.168.64.1/24")
        let cidr64_1a = try! CIDRAddress("192.168.64.1/24")
        #expect(cidr64_1 == cidr64_1a)
        #expect(cidr64_1.contains(cidr: cidr64_1a))
        #expect(cidr64_1a.contains(cidr: cidr64_1))
        #expect(cidr64_1.overlaps(cidr: cidr64_1a))
        #expect(cidr64_1a.overlaps(cidr: cidr64_1))

        let cidr64_2 = try! CIDRAddress("192.168.64.2/24")
        #expect(cidr64_1 != cidr64_2)

        let addr63_255 = try! IPv4Address("192.168.63.255")
        #expect(!cidr64_1.contains(ipv4: addr63_255))

        let addr64_0 = try! IPv4Address("192.168.64.0")
        #expect(cidr64_1.contains(ipv4: addr64_0))

        let addr64_255 = try! IPv4Address("192.168.64.255")
        #expect(cidr64_1.contains(ipv4: addr64_255))

        let addr65_0 = try! IPv4Address("192.168.65.0")
        #expect(!cidr64_1.contains(ipv4: addr65_0))

        let cidr64_prefix25 = try! CIDRAddress("192.168.64.0/25")
        #expect(cidr64_1.contains(cidr: cidr64_prefix25))
        #expect(!cidr64_prefix25.contains(cidr: cidr64_1))
        #expect(cidr64_1.overlaps(cidr: cidr64_prefix25))
        #expect(cidr64_prefix25.overlaps(cidr: cidr64_1))

        let cidr64_prefix25a = try! CIDRAddress("192.168.64.128/25")
        #expect(cidr64_1.contains(cidr: cidr64_prefix25a))
        #expect(!cidr64_prefix25a.contains(cidr: cidr64_1))
        #expect(cidr64_1.overlaps(cidr: cidr64_prefix25a))
        #expect(cidr64_prefix25a.overlaps(cidr: cidr64_1))

        let cidr63_prefix24 = try! CIDRAddress("192.168.63.0/24")
        #expect(!cidr64_1.contains(cidr: cidr63_prefix24))
        #expect(!cidr63_prefix24.contains(cidr: cidr64_1))
        #expect(!cidr64_1.overlaps(cidr: cidr63_prefix24))
        #expect(!cidr63_prefix24.overlaps(cidr: cidr64_1))

        let cidr65_prefix24 = try! CIDRAddress("192.168.65.0/24")
        #expect(!cidr64_1.contains(cidr: cidr65_prefix24))
        #expect(!cidr65_prefix24.contains(cidr: cidr64_1))
        #expect(!cidr64_1.overlaps(cidr: cidr65_prefix24))
        #expect(!cidr65_prefix24.overlaps(cidr: cidr64_1))
    }

    @Test
    func testBiggestSubnet() throws {
        let cidr = "1.2.3.4/0"
        let subnet = try CIDRAddress(cidr)
        #expect(try! IPv4Address("0.0.0.0") == subnet.lower)
        #expect(try! IPv4Address("1.2.3.4") == subnet.address)
        #expect(try! IPv4Address("255.255.255.255") == subnet.upper)
        #expect(0 == subnet.prefixLength)
        #expect(cidr == subnet.description)
    }

    @Test
    func testSmallestSubnet() throws {
        let cidr = "255.255.255.255/32"
        let subnet = try CIDRAddress(cidr)
        #expect(try! IPv4Address("255.255.255.255") == subnet.lower)
        #expect(try! IPv4Address("255.255.255.255") == subnet.address)
        #expect(try! IPv4Address("255.255.255.255") == subnet.upper)
        #expect(32 == subnet.prefixLength)
        #expect(cidr == subnet.description)
    }

    @Test
    func testJustRightSubnet() throws {
        let cidr = "192.168.64.10/24"
        let subnet = try CIDRAddress(cidr)
        #expect(try! IPv4Address("192.168.64.0") == subnet.lower)
        #expect(try! IPv4Address("192.168.64.10") == subnet.address)
        #expect(try! IPv4Address("192.168.64.255") == subnet.upper)
        #expect(24 == subnet.prefixLength)
        #expect(cidr == subnet.description)
    }

    @Test
    func testBiggestRangedSubnet() throws {
        let lower = try IPv4Address("127.255.255.255")
        let upper = try IPv4Address("128.0.0.0")
        let subnet = try CIDRAddress(lower: lower, upper: upper)
        #expect(try! IPv4Address("0.0.0.0") == subnet.lower)
        #expect(try! IPv4Address("127.255.255.255") == subnet.address)
        #expect(try! IPv4Address("255.255.255.255") == subnet.upper)
        #expect(0 == subnet.prefixLength)
        #expect("\(lower)/0" == subnet.description)
    }

    @Test
    func testSmallestRangedSubnet() throws {
        let lower = try IPv4Address("255.255.255.255")
        let subnet = try CIDRAddress(lower: lower, upper: lower)
        #expect(lower == subnet.lower)
        #expect(lower == subnet.address)
        #expect(lower == subnet.upper)
        #expect(32 == subnet.prefixLength)
        #expect("\(lower)/32" == subnet.description)
    }

    @Test
    func testJustRightRangedSubnet() throws {
        let lower = try IPv4Address("192.168.64.10")
        let upper = try IPv4Address("192.168.64.254")
        let subnet = try CIDRAddress(lower: lower, upper: upper)
        #expect(try! IPv4Address("192.168.64.0") == subnet.lower)
        #expect(try! IPv4Address("192.168.64.10") == subnet.address)
        #expect(try! IPv4Address("192.168.64.255") == subnet.upper)
        #expect(24 == subnet.prefixLength)
        #expect("\(lower)/24" == subnet.description)
        _ = 16 >> PrefixLength(2)
    }

    @Test
    func testCoding() async throws {
        let text = "200.100.50.25/12"
        let expected: CIDRAddress = try CIDRAddress(text)
        let data = try JSONEncoder().encode(expected)
        let actual = try JSONDecoder().decode(CIDRAddress.self, from: data)
        #expect(expected == actual)
    }
}
