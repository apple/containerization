//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

@testable import ContainerizationNetlink

class MockNetlinkSocket: NetlinkSocket {
    static let ENOMEM: Int32 = 12
    static let EOVERFLOW: Int32 = 75

    var pid: UInt32 = 0

    var requests: [[UInt8]] = []
    var responses: [[UInt8]] = []

    var responseIndex = 0

    public init() throws {}

    public func send(buf: UnsafeRawPointer!, len: Int, flags: Int32) throws -> Int {
        let ptr = buf.bindMemory(to: UInt8.self, capacity: len)
        requests.append(Array(UnsafeBufferPointer(start: ptr, count: len)))
        return len
    }

    public func recv(buf: UnsafeMutableRawPointer!, len: Int, flags: Int32) throws -> Int {
        guard responseIndex < responses.count else {
            throw NetlinkSocketError.recvFailure(rc: Self.ENOMEM)
        }

        let response = responses[responseIndex]
        guard len >= response.count else {
            throw NetlinkSocketError.recvFailure(rc: 75)
        }

        response.withUnsafeBytes { bytes in
            buf.copyMemory(from: bytes.baseAddress!, byteCount: response.count)
        }

        responseIndex += 1
        return response.count
    }
}
