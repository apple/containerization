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

#if os(Linux)

import Foundation
import Testing

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

@testable import ContainerizationOS

@Suite("Epoll tests")
final class EpollTests {

    @Suite("Mask option set")
    struct MaskTests {
        @Test
        func inputAndOutputAreDistinct() {
            let input = Epoll.Mask.input
            let output = Epoll.Mask.output
            #expect(input != output)
            #expect(input.isDisjoint(with: output))
        }

        @Test
        func readyToReadMatchesInput() {
            let mask = Epoll.Mask.input
            #expect(mask.readyToRead)
            #expect(!mask.readyToWrite)
        }

        @Test
        func readyToWriteMatchesOutput() {
            let mask = Epoll.Mask.output
            #expect(mask.readyToWrite)
            #expect(!mask.readyToRead)
        }

        @Test
        func combinedMask() {
            let mask: Epoll.Mask = [.input, .output]
            #expect(mask.readyToRead)
            #expect(mask.readyToWrite)
        }

        @Test
        func emptyMaskHasNoFlags() {
            let mask = Epoll.Mask(rawValue: 0)
            #expect(!mask.readyToRead)
            #expect(!mask.readyToWrite)
            #expect(!mask.isHangup)
            #expect(!mask.isRemoteHangup)
        }
    }

    private static func makePipe() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw POSIXError.fromErrno()
        }
        return (fds[0], fds[1])
    }

    @Test
    func addAndDeletePipeFD() throws {
        let epoll = try Epoll()
        let (readFD, writeFD) = try Self.makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }

        try epoll.add(readFD, mask: .input)
        try epoll.delete(readFD)
    }

    @Test
    func addInvalidFDThrows() throws {
        let epoll = try Epoll()
        #expect(throws: POSIXError.self) {
            try epoll.add(-1, mask: .input)
        }
    }

    @Test
    func deletingAlreadyClosedFDThrows() throws {
        let epoll = try Epoll()
        let (readFD, writeFD) = try Self.makePipe()
        try epoll.add(readFD, mask: .input)
        close(readFD)
        close(writeFD)
        #expect(throws: POSIXError.self) {
            try epoll.delete(readFD)
        }
    }

    @Test
    func doubleDeleteThrows() throws {
        let epoll = try Epoll()
        let (readFD, writeFD) = try Self.makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }

        try epoll.add(readFD, mask: .input)
        try epoll.delete(readFD)
        #expect(throws: POSIXError.self) {
            try epoll.delete(readFD)
        }
    }

    @Test
    func waitTimesOutWithNoEvents() throws {
        let epoll = try Epoll()
        let (readFD, writeFD) = try Self.makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }

        try epoll.add(readFD, mask: .input)
        // Timeout of 0 means return immediately.
        let events = epoll.wait(timeout: 0)
        try #require(events != nil, "wait should not return nil without shutdown")
        #expect(events!.isEmpty, "No data written, so no events expected")
    }

    @Test
    func waitReturnsReadableEvent() throws {
        let epoll = try Epoll()
        let (readFD, writeFD) = try Self.makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }

        try epoll.add(readFD, mask: .input)

        // Write some data to make the read end readable.
        var byte: UInt8 = 42
        let n = write(writeFD, &byte, 1)
        try #require(n == 1, "write to pipe should succeed")

        let events = epoll.wait(maxEvents: 4, timeout: 1000)
        try #require(events != nil, "wait should not return nil without shutdown")
        try #require(!events!.isEmpty, "Should have at least one event")

        let event = events!.first { $0.fd == readFD }
        try #require(event != nil, "Should have an event for the read fd")
        #expect(event!.mask.readyToRead)
    }

    @Test
    func waitReportsMultipleFDs() throws {
        let epoll = try Epoll()

        let (readFD1, writeFD1) = try Self.makePipe()
        defer {
            close(readFD1)
            close(writeFD1)
        }
        let (readFD2, writeFD2) = try Self.makePipe()
        defer {
            close(readFD2)
            close(writeFD2)
        }

        try epoll.add(readFD1, mask: .input)
        try epoll.add(readFD2, mask: .input)

        // Write to both pipes.
        var byte: UInt8 = 1
        _ = write(writeFD1, &byte, 1)
        _ = write(writeFD2, &byte, 1)

        let events = epoll.wait(maxEvents: 4, timeout: 1000)
        try #require(events != nil)
        #expect(events!.count == 2, "Should report events for both fds")

        let fds = Set(events!.map { $0.fd })
        #expect(fds.contains(readFD1))
        #expect(fds.contains(readFD2))
    }

    @Test
    func shutdownCausesWaitToReturnNil() throws {
        let epoll = try Epoll()
        let (readFD, writeFD) = try Self.makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }

        try epoll.add(readFD, mask: .input)

        epoll.shutdown()

        let events = epoll.wait(timeout: 0)
        #expect(events == nil, "wait should return nil after shutdown")
    }

    @Test
    func closingWriteEndSignalsHangup() throws {
        let epoll = try Epoll()
        let (readFD, writeFD) = try Self.makePipe()
        defer { close(readFD) }

        try epoll.add(readFD, mask: .input)

        // Close the write end to trigger a hangup on the read end.
        close(writeFD)

        let events = epoll.wait(maxEvents: 4, timeout: 1000)
        try #require(events != nil)
        try #require(!events!.isEmpty, "Should have a hangup event")

        let event = events!.first { $0.fd == readFD }
        try #require(event != nil)
        #expect(event!.mask.isHangup)
    }

    @Test
    func deletedFDIsNotReported() throws {
        let epoll = try Epoll()
        let (readFD, writeFD) = try Self.makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }

        try epoll.add(readFD, mask: .input)
        try epoll.delete(readFD)

        // Write data, should not produce events since we deleted the fd.
        var byte: UInt8 = 1
        _ = write(writeFD, &byte, 1)

        let events = epoll.wait(maxEvents: 4, timeout: 100)
        try #require(events != nil)
        #expect(events!.isEmpty, "Deleted fd should produce no events")
    }

    @Test
    func edgeTriggeredRequiresDrainBeforeRenotify() throws {
        let epoll = try Epoll()
        let (readFD, writeFD) = try Self.makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }

        try epoll.add(readFD, mask: .input)

        // Write data to make it readable.
        var byte: UInt8 = 99
        _ = write(writeFD, &byte, 1)

        // First wait should return the event.
        let events1 = epoll.wait(maxEvents: 4, timeout: 1000)
        try #require(events1 != nil)
        try #require(!events1!.isEmpty)

        // Without reading the data, a second immediate wait should NOT
        // re-trigger because of edge triggered semantics.
        let events2 = epoll.wait(maxEvents: 4, timeout: 0)
        try #require(events2 != nil)
        #expect(events2!.isEmpty, "Edge triggered should not re-fire without new activity")

        // Drain the pipe.
        var buf = [UInt8](repeating: 0, count: 16)
        _ = read(readFD, &buf, buf.count)

        // Write new data. This is a new edge, so it should trigger again.
        _ = write(writeFD, &byte, 1)
        let events3 = epoll.wait(maxEvents: 4, timeout: 1000)
        try #require(events3 != nil)
        #expect(!events3!.isEmpty, "New write after drain should trigger event")
    }
}

#endif  // os(Linux)
