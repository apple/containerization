//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import Darwin
import Foundation
import NIO
import Testing

@testable import Containerization

struct VsockListenerTests {
    @Test func connectionOwnerOutlivesTheDescriptorHandoff() throws {
        var handle: FileHandle? = FileHandle(forReadingAtPath: "/dev/null")
        try #require(handle != nil)

        var owner: ConnectionOwner? = ConnectionOwner()
        weak let weakOwner = owner
        retainConnectionOwner(owner!, for: handle!)
        owner = nil

        #expect(weakOwner != nil)

        try handle?.close()
        handle = nil

        #expect(weakOwner == nil)
    }

    @Test func vminitdRetainsConnectionOwnerWhileUsingDescriptor() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let group = MultiThreadedEventLoopGroup.singleton
        defer { try? peer.close() }

        weak var weakOwner: ConnectionOwner?
        var client: Vminitd?
        do {
            let handle = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: false)
            var owner: ConnectionOwner? = ConnectionOwner()
            weakOwner = owner
            retainConnectionOwner(owner!, for: handle)

            client = try await Vminitd(connection: handle, group: group)
            owner = nil
        }

        #expect(weakOwner != nil)

        try peer.close()
        try? await client?.close()
        client = nil

        #expect(weakOwner == nil)
    }
}

private final class ConnectionOwner {}
#endif
