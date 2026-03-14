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

import Foundation
import Testing

@testable import ContainerizationICMP

// Tests based on RFC 4861 Section 4.2 - Router Advertisement Message Format
struct RouterAdvertisementTests {

    @Test
    func testRouterAdvertisementRoundtrip() throws {
        // RFC 4861: Router Advertisement with typical values
        let ra = try RouterAdvertisement(
            currentHopLimit: 64,
            managedFlag: false,
            otherFlag: true,
            routerLifetime: 1800,
            reachableTime: 30000,
            retransTimer: 1000
        )

        var buffer = [UInt8](repeating: 0, count: RouterAdvertisement.size)
        let bytesWritten = try ra.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == RouterAdvertisement.size)
        #expect(RouterAdvertisement.size == 12)

        // Verify wire format per RFC 4861 Section 4.2
        // Byte 0: Cur Hop Limit
        #expect(buffer[0] == 64)

        // Byte 1: M (bit 7) and O (bit 6) flags
        // M=0, O=1 -> 0x40
        #expect(buffer[1] == 0x40)

        // Bytes 2-3: Router Lifetime (1800 = 0x0708 in network byte order)
        #expect(buffer[2] == 0x07)
        #expect(buffer[3] == 0x08)

        // Bytes 4-7: Reachable Time (30000 = 0x00007530 in network byte order)
        #expect(buffer[4] == 0x00)
        #expect(buffer[5] == 0x00)
        #expect(buffer[6] == 0x75)
        #expect(buffer[7] == 0x30)

        // Bytes 8-11: Retrans Timer (1000 = 0x000003E8 in network byte order)
        #expect(buffer[8] == 0x00)
        #expect(buffer[9] == 0x00)
        #expect(buffer[10] == 0x03)
        #expect(buffer[11] == 0xE8)

        var parsedRA = try RouterAdvertisement()
        let bytesRead = try parsedRA.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == RouterAdvertisement.size)
        #expect(parsedRA.currentHopLimit == 64)
        #expect(parsedRA.managedFlag == false)
        #expect(parsedRA.otherFlag == true)
        #expect(parsedRA.routerLifetime == 1800)
        #expect(parsedRA.reachableTime == 30000)
        #expect(parsedRA.retransTimer == 1000)
    }

    @Test
    func testRouterAdvertisementWithManagedFlag() throws {
        // RFC 4861: M flag indicates addresses available via DHCPv6
        let ra = try RouterAdvertisement(
            currentHopLimit: 64,
            managedFlag: true,
            otherFlag: false,
            routerLifetime: 9000,
            reachableTime: 0,
            retransTimer: 0
        )

        var buffer = [UInt8](repeating: 0, count: RouterAdvertisement.size)
        _ = try ra.appendBuffer(&buffer, offset: 0)

        // M=1, O=0 -> 0x80
        #expect(buffer[1] == 0x80)

        var parsedRA = try RouterAdvertisement()
        _ = try parsedRA.bindBuffer(&buffer, offset: 0)

        #expect(parsedRA.managedFlag == true)
        #expect(parsedRA.otherFlag == false)
    }

    @Test
    func testRouterAdvertisementWithBothFlags() throws {
        // RFC 4861: Both M and O flags set
        let ra = try RouterAdvertisement(
            currentHopLimit: 255,
            managedFlag: true,
            otherFlag: true,
            routerLifetime: 0xFFFF,
            reachableTime: 0xFFFF_FFFF,
            retransTimer: 0xFFFF_FFFF
        )

        var buffer = [UInt8](repeating: 0, count: RouterAdvertisement.size)
        _ = try ra.appendBuffer(&buffer, offset: 0)

        // M=1, O=1 -> 0xC0
        #expect(buffer[1] == 0xC0)

        var parsedRA = try RouterAdvertisement()
        _ = try parsedRA.bindBuffer(&buffer, offset: 0)

        #expect(parsedRA.currentHopLimit == 255)
        #expect(parsedRA.managedFlag == true)
        #expect(parsedRA.otherFlag == true)
        #expect(parsedRA.routerLifetime == 0xFFFF)
        #expect(parsedRA.reachableTime == 0xFFFF_FFFF)
        #expect(parsedRA.retransTimer == 0xFFFF_FFFF)
    }

    @Test
    func testRouterAdvertisementZeroLifetime() throws {
        // RFC 4861 Section 6.2.5: Router Lifetime 0 means not a default router
        let ra = try RouterAdvertisement(
            currentHopLimit: 64,
            managedFlag: false,
            otherFlag: false,
            routerLifetime: 0,
            reachableTime: 0,
            retransTimer: 0
        )

        var buffer = [UInt8](repeating: 0, count: RouterAdvertisement.size)
        _ = try ra.appendBuffer(&buffer, offset: 0)

        var parsedRA = try RouterAdvertisement()
        _ = try parsedRA.bindBuffer(&buffer, offset: 0)

        #expect(parsedRA.routerLifetime == 0)
    }
}
