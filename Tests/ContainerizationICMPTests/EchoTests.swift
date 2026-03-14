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

// Tests based on RFC 792 (ICMPv4) and RFC 4443 (ICMPv6) Echo Request/Reply
struct EchoTests {

    // MARK: - Echo Header Tests (RFC 792, RFC 4443)

    @Test
    func testEchoRoundtrip() throws {
        let echo = try Echo(identifier: 0x1234, sequenceNumber: 0x5678)

        var buffer = [UInt8](repeating: 0, count: Echo.size)
        let bytesWritten = try echo.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == Echo.size)

        // Verify wire format (Big Endian)
        // Identifier 0x1234 -> 0x12, 0x34
        #expect(buffer[0] == 0x12)
        #expect(buffer[1] == 0x34)
        // Sequence 0x5678 -> 0x56, 0x78
        #expect(buffer[2] == 0x56)
        #expect(buffer[3] == 0x78)

        var parsedEcho = try Echo(identifier: 0, sequenceNumber: 0)
        let bytesRead = try parsedEcho.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == Echo.size)
        #expect(parsedEcho.identifier == 0x1234)
        #expect(parsedEcho.sequenceNumber == 0x5678)
    }

    @Test
    func testEchoPayloadRTTRoundtrip() throws {
        let now = Date()
        let payload = EchoPayloadRTT(date: now)

        var buffer = [UInt8](repeating: 0, count: EchoPayloadRTT.size)
        let bytesWritten = try payload.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == EchoPayloadRTT.size)

        var parsedPayload = EchoPayloadRTT()
        let bytesRead = try parsedPayload.bindBuffer(&buffer, offset: 0)

        #expect(bytesRead == EchoPayloadRTT.size)
        // Date comparison might need tolerance due to Double precision in TimeInterval
        #expect(abs(parsedPayload.date.timeIntervalSinceReferenceDate - now.timeIntervalSinceReferenceDate) < 0.001)
    }

    @Test
    func testEchoPayloadRTTCalculation() {
        let past = Date(timeIntervalSinceReferenceDate: 1000)
        let payload = EchoPayloadRTT(date: past)

        let future = Date(timeIntervalSinceReferenceDate: 1001.5)
        let rtt = payload.rtt(atDate: future)

        #expect(rtt == 1.5)
    }

    // MARK: - Process ID as Identifier (RFC 792 Common Practice)

    @Test
    func testEchoWithProcessID() throws {
        // RFC 792: Identifier is often set to process ID
        let processID = UInt16(truncatingIfNeeded: 12345)
        let echo = try Echo(identifier: processID, sequenceNumber: 1)

        var buffer = [UInt8](repeating: 0, count: Echo.size)
        _ = try echo.appendBuffer(&buffer, offset: 0)

        var parsedEcho = try Echo(identifier: 0, sequenceNumber: 0)
        _ = try parsedEcho.bindBuffer(&buffer, offset: 0)

        #expect(parsedEcho.identifier == processID)
        #expect(parsedEcho.sequenceNumber == 1)
    }

    @Test
    func testEchoSequenceIncrement() throws {
        // RFC 792: Sequence numbers typically increment for each echo
        var echoes: [Echo] = []
        for seq in 1...5 {
            let echo = try Echo(identifier: 100, sequenceNumber: UInt16(seq))
            echoes.append(echo)
        }

        #expect(echoes[0].sequenceNumber == 1)
        #expect(echoes[4].sequenceNumber == 5)
    }

    // MARK: - Echo Payload Edge Cases

    @Test
    func testEchoPayloadRTTWithFutureDate() {
        // Test RTT with future date
        let future = Date(timeIntervalSinceReferenceDate: 2000)
        let payload = EchoPayloadRTT(date: future)

        let past = Date(timeIntervalSinceReferenceDate: 1500)
        let rtt = payload.rtt(atDate: past)

        // RTT should be negative when "now" is before send time
        #expect(rtt == -500.0)
    }

    @Test
    func testEchoPayloadRTTDefaultDate() {
        // Test that default constructor uses current time
        let before = Date()
        let payload = EchoPayloadRTT()
        let after = Date()

        // Payload date should be between before and after
        #expect(payload.date >= before)
        #expect(payload.date <= after)
    }

    @Test
    func testEchoPayloadRTTDefaultCalculation() {
        // Test RTT calculation with default (current) date
        let past = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate - 1.0)
        let payload = EchoPayloadRTT(date: past)

        let rtt = payload.rtt()  // Uses Date() internally

        // RTT should be approximately 1 second (with some tolerance for execution time)
        #expect(rtt >= 1.0)
        #expect(rtt <= 1.1)
    }

    // MARK: - Wire Format Tests

    @Test
    func testEchoZeroValues() throws {
        // RFC 792: Test with all zero values
        let echo = try Echo(identifier: 0, sequenceNumber: 0)

        var buffer = [UInt8](repeating: 0, count: Echo.size)
        let bytesWritten = try echo.appendBuffer(&buffer, offset: 0)

        #expect(bytesWritten == Echo.size)
        #expect(buffer[0] == 0)
        #expect(buffer[1] == 0)
        #expect(buffer[2] == 0)
        #expect(buffer[3] == 0)
    }

    @Test
    func testEchoMaxValues() throws {
        // RFC 792: Test with maximum values
        let echo = try Echo(identifier: 0xFFFF, sequenceNumber: 0xFFFF)

        var buffer = [UInt8](repeating: 0, count: Echo.size)
        _ = try echo.appendBuffer(&buffer, offset: 0)

        #expect(buffer[0] == 0xFF)
        #expect(buffer[1] == 0xFF)
        #expect(buffer[2] == 0xFF)
        #expect(buffer[3] == 0xFF)

        var parsedEcho = try Echo(identifier: 0, sequenceNumber: 0)
        _ = try parsedEcho.bindBuffer(&buffer, offset: 0)

        #expect(parsedEcho.identifier == 0xFFFF)
        #expect(parsedEcho.sequenceNumber == 0xFFFF)
    }

    @Test
    func testEchoPayloadSize() {
        // RFC 792: Verify payload is standard 56 bytes
        #expect(EchoPayloadRTT.size == 56)
    }

    @Test
    func testEchoHeaderSize() {
        // RFC 792/4443: Echo header is 4 bytes (identifier + sequence)
        #expect(Echo.size == 4)
    }

    @Test
    func testEchoPayloadRTTPrecision() throws {
        // Test that timestamp preserves microsecond precision
        let preciseTime = Date(timeIntervalSinceReferenceDate: 1234567.123456)
        let payload = EchoPayloadRTT(date: preciseTime)

        var buffer = [UInt8](repeating: 0, count: EchoPayloadRTT.size)
        _ = try payload.appendBuffer(&buffer, offset: 0)

        var parsedPayload = EchoPayloadRTT()
        _ = try parsedPayload.bindBuffer(&buffer, offset: 0)

        // Should preserve precision within Double's limits
        #expect(abs(parsedPayload.date.timeIntervalSinceReferenceDate - preciseTime.timeIntervalSinceReferenceDate) < 0.000001)
    }
}
