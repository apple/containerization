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

@testable import ContainerizationNetlink

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct NetlinkSocketTest {
    @Test(arguments: [socklen_t(0), socklen_t(SockaddrNetlink.size - 1), socklen_t(SockaddrNetlink.size + 1)])
    func rejectsUnexpectedAddressLength(length: socklen_t) throws {
        var buffer = try addressBuffer()
        let error = NetlinkSocketError.invalidSocketNameLength(expected: 12, actual: length)
        #expect(throws: error) {
            try SockaddrNetlink.boundPortIdentifier(buffer: &buffer, length: length)
        }
        #expect(error.description == "invalid netlink socket address length, expected 12 bytes, got \(length)")
    }

    @Test func rejectsUnexpectedAddressFamily() throws {
        var buffer = try addressBuffer(family: AddressFamily.AF_INET)
        let error = NetlinkSocketError.invalidSocketNameFamily(expected: 16, actual: 2)
        #expect(throws: error) {
            try SockaddrNetlink.boundPortIdentifier(buffer: &buffer, length: 12)
        }
        #expect(error.description == "invalid netlink socket address family, expected 16, got 2")
    }

    @Test func rejectsZeroPortIdentifier() throws {
        var buffer = try addressBuffer(pid: 0)
        #expect(throws: NetlinkSocketError.zeroSocketPortIdentifier) {
            try SockaddrNetlink.boundPortIdentifier(buffer: &buffer, length: 12)
        }
        #expect(
            NetlinkSocketError.zeroSocketPortIdentifier.description
                == "invalid netlink socket port identifier, expected a nonzero value, got 0"
        )
    }

    @Test(arguments: [UInt32(1), UInt32.max])
    func acceptsAssignedPortIdentifier(pid: UInt32) throws {
        var buffer = try addressBuffer(pid: pid)
        #expect(try SockaddrNetlink.boundPortIdentifier(buffer: &buffer, length: 12) == pid)
    }

    @Test func socketNameFailurePreservesErrno() {
        #expect(NetlinkSocketError.socketNameFailure(rc: EBADF).description == "could not get netlink socket name, rc = \(EBADF)")
    }

    private func addressBuffer(family: UInt16 = AddressFamily.AF_NETLINK, pid: UInt32 = 42) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: SockaddrNetlink.size)
        _ = try SockaddrNetlink(family: family, pid: pid).appendBuffer(&buffer, offset: 0)
        return buffer
    }

    #if os(Linux)
    @Test func concurrentSocketsReceiveDistinctPortIdentifiers() throws {
        let sockets = try (0..<8).map { _ in
            try DefaultNetlinkSocket()
        }
        let identifiers = sockets.map(\.pid)

        #expect(identifiers.allSatisfy { $0 != 0 })
        #expect(Set(identifiers).count == sockets.count)
    }
    #endif
}
