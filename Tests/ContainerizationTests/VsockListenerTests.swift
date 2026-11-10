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

import ContainerizationOS
import Foundation
import Synchronization
import Testing

@testable import Containerization

struct VsockListenerTests {
    private func pair() throws -> (Int32, FileHandle) {
        var fds: [Int32] = [-1, -1]
        #if canImport(Glibc)
        let type = Int32(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        try #require(socketpair(AF_UNIX, type, 0, &fds) == 0)
        return (fds[0], FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }

    private func expectEOF(_ peer: FileHandle) throws {
        var event = pollfd(fd: peer.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try #require(poll(&event, 1, 1000) > 0)
        var byte: UInt8 = 0
        #expect(read(peer.fileDescriptor, &byte, 1) == 0)
    }

    @Test func finishedListenerDrainsAcrossPublicIteratorsAndReleasesBackendOnce() async throws {
        let releases = Mutex(0)
        let listener = VsockListener(port: 1) { _ in releases.withLock { $0 += 1 } }
        let (firstFd, firstPeer) = try pair()
        let acceptedFirst = listener.yieldOwned(DescriptorTransfer(adopting: firstFd))
        #expect(acceptedFirst)
        let first = try #require(await listener.first(where: { _ in true }))
        try first.close()
        try expectEOF(firstPeer)

        let (queuedFd, queuedPeer) = try pair()
        let acceptedQueued = listener.yieldOwned(DescriptorTransfer(adopting: queuedFd))
        #expect(acceptedQueued)
        try listener.finish()
        try listener.finish()
        #expect(releases.withLock { $0 } == 1)
        let queued = try #require(await listener.first(where: { _ in true }))
        try queued.close()
        try expectEOF(queuedPeer)
        #expect(await listener.first(where: { _ in true }) == nil)
    }

    @Test func discardClosesQueuedAndLateConnections() throws {
        let listener = VsockListener(port: 1) { _ in }
        let (first, firstPeer) = try pair()
        let acceptedFirst = listener.yieldOwned(DescriptorTransfer(adopting: first))
        #expect(acceptedFirst)
        try listener.cancelAndDiscard()
        try expectEOF(firstPeer)
        let (late, latePeer) = try pair()
        let acceptedLate = listener.yieldOwned(DescriptorTransfer(adopting: late))
        #expect(!acceptedLate)
        try expectEOF(latePeer)
    }

    @Test func droppingUnconsumedListenerClosesPendingDescriptors() throws {
        let (fd, peer) = try pair()
        do {
            let listener = VsockListener(port: 1) { _ in }
            let acceptedFd = listener.yieldOwned(DescriptorTransfer(adopting: fd))
            #expect(acceptedFd)
        }
        try expectEOF(peer)
    }

    @Test func ownedDeliveryTransfersClosingResponsibility() async throws {
        let listener = VsockListener(port: 1) { _ in }
        let (fd, peer) = try pair()
        let acceptedFd = listener.yieldOwned(DescriptorTransfer(adopting: fd))
        #expect(acceptedFd)
        do {
            guard let token = try await listener.nextOwned() else {
                Issue.record("queued descriptor was not delivered")
                return
            }
            let owner = token.takeOwner()
            defer { try? owner.close() }
            try listener.cancelAndDiscard()
            let use = try owner.acquire()
            defer { use.end() }
            let byte: [UInt8] = [42]
            try #require(byte.withUnsafeBytes { write(use.fileDescriptor, $0.baseAddress, 1) } == 1)
            var received: UInt8 = 0
            #expect(read(peer.fileDescriptor, &received, 1) == 1)
            #expect(received == 42)
        }
        try expectEOF(peer)
    }

    @Test(arguments: [false, true])
    func cancellationReleasesBackendAndRejectsArrivals(publicIterator: Bool) async throws {
        let releases = Mutex(0)
        let listener = VsockListener(port: 1) { _ in releases.withLock { $0 += 1 } }
        let completed = Mutex(false)
        let waiting = Task {
            defer { completed.withLock { $0 = true } }
            // Cancelling before next() exercises the already-cancelled path deterministically.
            withUnsafeCurrentTask { $0?.cancel() }
            if publicIterator {
                var iterator = listener.makeAsyncIterator()
                if let handle = await iterator.next() {
                    try? handle.close()
                    Issue.record("cancelled empty listener delivered a handle")
                }
            } else if let token = try await listener.nextOwned() {
                let owner = token.takeOwner()
                try? owner.close()
                Issue.record("cancelled empty listener delivered a descriptor")
            }
        }
        defer { waiting.cancel() }
        waiting.cancel()
        let deadline = ContinuousClock.now + .seconds(5)
        while !completed.withLock({ $0 }) {
            try #require(ContinuousClock.now < deadline, "cancelled listener did not finish")
            try await Task.sleep(for: .milliseconds(1))
        }
        try await waiting.value
        #expect(releases.withLock { $0 } == 1)
        let (fd, peer) = try pair()
        let acceptedFd = listener.yieldOwned(DescriptorTransfer(adopting: fd))
        #expect(!acceptedFd)
        try expectEOF(peer)
    }
}
