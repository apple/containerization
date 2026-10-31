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

import CShim
import Foundation
import Testing

@testable import ContainerizationOS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
import Musl
#endif

@Suite("Owned descriptor receipt", .timeLimit(.minutes(1)))
struct DescriptorReceiptTests {
    private func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        let result = socketpair(AF_UNIX, _SOCK_STREAM, 0, &fds)
        try #require(result == 0)
        // Synchronous receipt cannot be interrupted by the suite's time limit.
        var timeout = timeval()
        timeout.tv_sec = 5
        for fd in fds {
            try #require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        }
        return (fds[0], fds[1])
    }

    private func sendRights(_ descriptors: [Int32], over fd: Int32, payload: Bool = true) throws {
        let length = Int(CZ_CMSG_SPACE(descriptors.count * MemoryLayout<Int32>.size))
        let control = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        control.initializeMemory(as: UInt8.self, repeating: 0, count: length)
        let header = control.bindMemory(to: cmsghdr.self, capacity: 1)
        header.pointee.cmsg_level = SOL_SOCKET
        header.pointee.cmsg_type = Int32(SCM_RIGHTS)
        header.pointee.cmsg_len = numericCast(CZ_CMSG_LEN(descriptors.count * MemoryLayout<Int32>.size))
        let data = try #require(CZ_CMSG_DATA(header))
        descriptors.withUnsafeBytes { bytes in data.copyMemory(from: bytes.baseAddress ?? UnsafeRawPointer(control), byteCount: bytes.count) }
        var byte: UInt8 = 1
        let result = withUnsafeMutablePointer(to: &byte) { bytePointer in
            var vector = iovec(iov_base: bytePointer, iov_len: payload ? 1 : 0)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr()
                message.msg_iov = vectorPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = numericCast(length)
                #if os(Linux)
                return sendmsg(fd, &message, Int32(MSG_NOSIGNAL))
                #else
                return sendmsg(fd, &message, 0)
                #endif
            }
        }
        guard result == (payload ? 1 : 0) else { throw SocketError.withErrno("sendmsg failed", errno: errno) }
    }

    @Test func rawReceiptTransfersAUsableDescriptor() throws {
        let (sender, receiver) = try pair()
        defer {
            close(sender)
            close(receiver)
        }
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0)
        defer {
            close(pipeFDs[0])
            close(pipeFDs[1])
        }
        #if canImport(Darwin)
        // Darwin can deliver rights without payload; recvmsg returning zero is not EOF.
        try sendRights([pipeFDs[0]], over: sender, payload: false)
        #else
        try sendRights([pipeFDs[0]], over: sender)
        #endif
        let socket = try Socket(fd: receiver, type: UnixType(path: "/tmp/receipt-test"), closeOnDeinit: false, connected: true)
        let received = try socket.receiveFileDescriptor()
        defer { close(received) }
        #expect(fcntl(received, F_GETFD) & FD_CLOEXEC != 0)
        var byte: UInt8 = 42
        try #require(write(pipeFDs[1], &byte, 1) == 1)
        byte = 0
        #expect(read(received, &byte, 1) == 1)
        #expect(byte == 42)
    }

    #if canImport(Darwin)
    private static let maximumRights = (2048 - Int(CZ_CMSG_LEN(0))) / MemoryLayout<UnsafeRawPointer>.size
    #else
    private static let maximumRights = 253
    #endif

    @Test func rejectsAndClosesEveryReceivedRight() throws {
        let (sender, receiver) = try pair()
        defer {
            close(sender)
            close(receiver)
        }
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[0]) }
        do {
            defer { close(pipeFDs[1]) }
            try sendRights(Array(repeating: pipeFDs[1], count: Self.maximumRights), over: sender)
        }
        let received = CZ_receive_fd(receiver)
        let error = errno
        #expect(received == -1)
        #expect(error == EPROTO)
        // EOF, rather than would-block, proves no delivered writer survived rejection.
        try #require(fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK) == 0)
        var byte: UInt8 = 0
        #expect(read(pipeFDs[0], &byte, 1) == 0)
    }

    #if os(Linux)
    // SO_PASSPIDFD's Linux UAPI value is absent from older libc headers.
    private static let passPidfd: Int32 = 76

    private func ownPIDDescriptors() throws -> Set<String> {
        let expectedPID = "Pid:\t\(getpid())"
        return Set(
            try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").filter { descriptor in
                guard
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(descriptor)")) == "anon_inode:[pidfd]",
                    let info = try? String(contentsOfFile: "/proc/self/fdinfo/\(descriptor)", encoding: .utf8)
                else { return false }
                return info.split(separator: "\n").contains { $0 == expectedPID }
            })
    }

    @Test(arguments: [SO_PASSCRED, passPidfd])
    func unexpectedCredentialRecordClosesAllReceivedDescriptors(_ option: Int32) throws {
        let (sender, receiver) = try pair()
        defer {
            close(sender)
            close(receiver)
        }
        var enabled: Int32 = 1
        let result = setsockopt(receiver, SOL_SOCKET, option, &enabled, socklen_t(MemoryLayout<Int32>.size))
        if option == Self.passPidfd && result == -1 && errno == ENOPROTOOPT { return }
        try #require(result == 0)
        // Other tests open descriptors concurrently; count only pidfds for this process.
        let pidfdsBefore = option == Self.passPidfd ? try ownPIDDescriptors() : []
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[0]) }
        do {
            defer { close(pipeFDs[1]) }
            try sendRights([pipeFDs[1]], over: sender)
        }
        let received = CZ_receive_fd(receiver)
        let error = errno
        #expect(received == -1)
        #expect(error == EPROTO)
        try #require(fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK) == 0)
        var byte: UInt8 = 0
        #expect(read(pipeFDs[0], &byte, 1) == 0)
        if option == Self.passPidfd {
            #expect(try ownPIDDescriptors() == pidfdsBefore)
        }
    }
    #endif
}
