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
import Synchronization
import Testing

@testable import VminitdCore

@Suite("Process supervisor tests")
struct ProcessSupervisorTests {
    private struct State {
        var closed = false
        var replacementFD: Int32?
        var deliveries = 0
        var failure: String?
    }

    private static func writeByte(to fd: Int32) throws {
        var byte: UInt8 = 1
        try #require(Foundation.write(fd, &byte, 1) == 1)
    }

    @Test
    func ignoresEventsFromPreviousRegistrationInSameBatch() throws {
        let supervisor = ProcessSupervisor.default
        let gate = Pipe()
        let candidates = [Pipe(), Pipe()]
        let barrier = Pipe()
        let pipes = [gate] + candidates + [barrier]
        let readers = candidates.map { $0.fileHandleForReading.fileDescriptor }
        let writers = candidates.map { $0.fileHandleForWriting.fileDescriptor }
        let barrierWriter = barrier.fileHandleForWriting.fileDescriptor
        let state = Mutex(State())
        let gateEntered = DispatchSemaphore(value: 0)
        let releaseGate = DispatchSemaphore(value: 0)
        let batchFinished = DispatchSemaphore(value: 0)
        let replacementCalled = DispatchSemaphore(value: 0)

        defer {
            releaseGate.signal()
            state.withLock { current in
                current.closed = true
                for pipe in pipes {
                    try? supervisor.unregisterFd(pipe.fileHandleForReading.fileDescriptor)
                    try? pipe.fileHandleForReading.close()
                    try? pipe.fileHandleForWriting.close()
                }
            }
        }

        try supervisor.registerFd(gate.fileHandleForReading.fileDescriptor, mask: .input) { _ in
            gateEntered.signal()
            if releaseGate.wait(timeout: .now() + 5) != .success {
                state.withLock { $0.failure = "Timed out waiting to release the poller" }
                batchFinished.signal()
            }
        }
        try Self.writeByte(to: gate.fileHandleForWriting.fileDescriptor)
        try #require(gateEntered.wait(timeout: .now() + 5) == .success)

        try supervisor.registerFd(barrier.fileHandleForReading.fileDescriptor, mask: .input) { _ in
            batchFinished.signal()
        }
        for (index, fd) in readers.enumerated() {
            let otherFD = readers[1 - index]
            try supervisor.registerFd(fd, mask: .input) { _ in
                state.withLock { current in
                    guard !current.closed, current.replacementFD == nil else { return }
                    do {
                        // Whichever event runs first replaces the registration for the other event in this batch.
                        try supervisor.unregisterFd(otherFD)
                        var byte: UInt8 = 0
                        try #require(Foundation.read(otherFD, &byte, 1) == 1)
                        try supervisor.registerFd(otherFD, mask: .input) { _ in
                            state.withLock { current in
                                guard !current.closed else { return }
                                current.deliveries += 1
                                replacementCalled.signal()
                            }
                        }
                        current.replacementFD = otherFD
                        // This event can only arrive in a later batch, after the stale event has been considered.
                        try Self.writeByte(to: barrierWriter)
                    } catch {
                        current.failure = String(describing: error)
                        batchFinished.signal()
                    }
                }
            }
        }

        // Both descriptors must be ready before the poller collects its next batch.
        for writer in writers { try Self.writeByte(to: writer) }
        releaseGate.signal()
        try #require(batchFinished.wait(timeout: .now() + 5) == .success)
        let (replacementFD, deliveries, failure) = state.withLock {
            ($0.replacementFD, $0.deliveries, $0.failure)
        }
        try #require(failure == nil, "\(failure ?? "")")
        #expect(deliveries == 0)

        let fd = try #require(replacementFD)
        let index = try #require(readers.firstIndex(of: fd))
        try Self.writeByte(to: writers[index])
        try #require(replacementCalled.wait(timeout: .now() + 5) == .success)
        #expect(state.withLock { $0.deliveries } == 1)
    }
}

#endif
