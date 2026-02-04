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

import CShim
import Foundation
import Testing

@testable import ContainerizationOS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("Socket SCM_RIGHTS tests")
final class SocketTests {

    /// Helper function to send a file descriptor via SCM_RIGHTS
    private func sendFileDescriptor(socket: Socket, fd: Int32) throws {
        var msg = msghdr()
        var iov = iovec()
        var buf: UInt8 = 0

        iov.iov_base = withUnsafeMutablePointer(to: &buf) { UnsafeMutableRawPointer($0) }
        iov.iov_len = 1

        msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
        msg.msg_iovlen = 1

        // Control message buffer for file descriptor
        var cmsgBuf = [UInt8](repeating: 0, count: Int(CZ_CMSG_SPACE(Int(MemoryLayout<Int32>.size))))

        msg.msg_control = withUnsafeMutablePointer(to: &cmsgBuf[0]) { UnsafeMutableRawPointer($0) }
        msg.msg_controllen = socklen_t(cmsgBuf.count)

        // Set up control message
        let cmsgPtr = withUnsafeMutablePointer(to: &msg) { CZ_CMSG_FIRSTHDR($0) }
        guard let cmsg = cmsgPtr else {
            throw SocketError.invalidFileDescriptor
        }

        cmsg.pointee.cmsg_level = SOL_SOCKET
        cmsg.pointee.cmsg_type = SCM_RIGHTS
        cmsg.pointee.cmsg_len = socklen_t(CZ_CMSG_LEN(Int(MemoryLayout<Int32>.size)))

        guard let dataPtr = CZ_CMSG_DATA(cmsg) else {
            throw SocketError.invalidFileDescriptor
        }

        dataPtr.assumingMemoryBound(to: Int32.self).pointee = fd

        let sendResult = withUnsafeMutablePointer(to: &msg) { msgPtr in
            sendmsg(socket.fileDescriptor, msgPtr, 0)
        }

        guard sendResult >= 0 else {
            throw SocketError.withErrno("sendmsg failed", errno: errno)
        }
    }

    @Test
    func testSCMRightsFileDescriptorPassing() throws {
        // Create a socketpair for testing
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try #require(result == 0, "socketpair should succeed")

        defer {
            close(fds[0])
            close(fds[1])
        }

        // Use a dummy UnixType since we won't be using it for bind/connect/listen
        let socketType = try UnixType(path: "/tmp/dummy")
        let sendSocket = Socket(fd: fds[0], type: socketType, closeOnDeinit: false, connected: true)
        let recvSocket = Socket(fd: fds[1], type: socketType, closeOnDeinit: false, connected: true)

        // Create a temporary file to send its descriptor
        let fileManager = FileManager.default
        let tempDir = fileManager.uniqueTemporaryDirectory()
        defer { try? fileManager.removeItem(at: tempDir) }

        let testFilePath = tempDir.appending(path: "test.txt")
        let testContent = "Hello, SCM_RIGHTS!"
        try testContent.write(to: testFilePath, atomically: true, encoding: .utf8)

        let testFileHandle = try FileHandle(forReadingFrom: testFilePath)
        defer { try? testFileHandle.close() }

        let originalFD = testFileHandle.fileDescriptor

        try sendFileDescriptor(socket: sendSocket, fd: originalFD)
        let receivedFd = try recvSocket.receiveFileDescriptor()
        let receivedFileHandle = FileHandle(fileDescriptor: receivedFd)
        defer { try? receivedFileHandle.close() }

        try #require(receivedFileHandle.fileDescriptor != originalFD, "Received FD should be different")
        try #require(receivedFileHandle.fileDescriptor >= 0, "Received FD should be valid")

        let data = try receivedFileHandle.readToEnd()
        try #require(data != nil, "Should be able to read from received FD")

        let receivedContent = String(data: data!, encoding: .utf8)
        #expect(receivedContent == testContent, "Content should match original file")
    }
}
