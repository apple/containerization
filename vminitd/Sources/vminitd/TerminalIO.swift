//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
import Logging
import SendableProperty

final class TerminalIO: ManagedProcess.IO & Sendable {
    private let parent: Terminal
    private let child: Terminal
    private let log: Logger?

    private let stdio: HostStdio
    @SendableProperty
    private var stdinSocket: Socket?
    @SendableProperty
    private var stdoutSocket: Socket?

    init(
        process: inout Command,
        stdio: HostStdio,
        log: Logger?
    ) throws {
        let pair = try Terminal.create()
        self.parent = pair.parent
        self.child = pair.child
        self.stdio = stdio
        self.log = log

        let ptyHandle = child.handle
        let useHandles = stdio.stdin != nil || stdio.stdout != nil
        // We currently set stdin to the controlling terminal always, so
        // it must be a valid pty descriptor.
        process.stdin = useHandles ? ptyHandle : nil

        let stdoutHandle = useHandles ? ptyHandle : nil
        process.stdout = stdoutHandle
        process.stderr = stdoutHandle
    }

    func resize(size: Terminal.Size) throws {
        if self.stdio.stdin != nil {
            try parent.resize(size: size)
        }
    }

    func start() throws {
        if let stdinPort = self.stdio.stdin {
            let type = VsockType(
                port: stdinPort,
                cid: VsockType.hostCID
            )
            let stdinSocket = try Socket(type: type, closeOnDeinit: false)
            try stdinSocket.connect()
            self.stdinSocket = stdinSocket

            try relay(
                readFromFd: stdinSocket.fileDescriptor,
                writeToFd: self.parent.handle.fileDescriptor
            )
        }

        if let stdoutPort = self.stdio.stdout {
            let type = VsockType(
                port: stdoutPort,
                cid: VsockType.hostCID
            )
            let stdoutSocket = try Socket(type: type, closeOnDeinit: false)
            try stdoutSocket.connect()
            self.stdoutSocket = stdoutSocket

            try relay(
                readFromFd: self.parent.handle.fileDescriptor,
                writeToFd: stdoutSocket.fileDescriptor
            )
        }
    }

    func relay(readFromFd: Int32, writeToFd: Int32) throws {
        let readFrom = OSFile(fd: readFromFd)
        let writeTo = OSFile(fd: writeToFd)
        // `buf` and `didCleanup` aren't used concurrently.
        nonisolated(unsafe) let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))
        nonisolated(unsafe) var didCleanup = false

        let cleanupRelay: @Sendable () -> Void = {
            if didCleanup { return }
            didCleanup = true
            self.cleanupRelay(readFd: readFromFd, writeFd: writeToFd, buffer: buf, log: self.log)
        }

        try ProcessSupervisor.default.poller.add(readFromFd, mask: EPOLLIN) { mask in
            if mask.isHangup && !mask.readyToRead {
                cleanupRelay()
                return
            }
            // Loop so that in the case that someone wrote > buf.count down the pipe
            // we properly will drain it fully.
            while true {
                let r = readFrom.read(buf)
                if r.read > 0 {
                    let view = UnsafeMutableBufferPointer(
                        start: buf.baseAddress,
                        count: r.read
                    )

                    let w = writeTo.write(view)
                    if w.wrote != r.read {
                        self.log?.error("stopping relay: short write for stdio")
                        cleanupRelay()
                        return
                    }
                }

                switch r.action {
                case .error(let errno):
                    self.log?.error("failed with errno \(errno) while reading for fd \(readFromFd)")
                    fallthrough
                case .eof:
                    cleanupRelay()
                    self.log?.debug("closing relay for \(readFromFd)")
                    return
                case .again:
                    // We read all we could, exit.
                    if mask.isHangup {
                        cleanupRelay()
                    }
                    return
                default:
                    break
                }
            }
        }
    }

    func cleanupRelay(readFd: Int32, writeFd: Int32, buffer: UnsafeMutableBufferPointer<UInt8>, log: Logger?) {
        do {
            // We could alternatively just allocate buffers in the constructor, and free them
            // on close().
            buffer.deallocate()
            try ProcessSupervisor.default.poller.delete(readFd)
        } catch {
            self.log?.error("failed to delete pipe fd from epoll \(readFd): \(error)")
        }
        if Foundation.close(writeFd) != 0 {
            let err = POSIXError.fromErrno()
            self.log?.error("failed to close write fd for TerminalIO relay: \(String(describing:err))")
        }
    }

    func close() throws {
        try parent.close()
    }

    func closeAfterExec() throws {
        try child.close()
    }
}
