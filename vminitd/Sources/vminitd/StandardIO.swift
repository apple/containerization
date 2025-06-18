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

import Containerization
import ContainerizationOS
import Foundation
import Logging
import SendableProperty
import Synchronization

final class StandardIO: ManagedProcess.IO & Sendable {
    private let log: Logger?

    private let stdio: HostStdio
    private let stdinPipe: Pipe?
    private let stdoutPipe: Pipe?
    private let stderrPipe: Pipe?

    @SendableProperty
    private var stdinSocket: Socket?
    @SendableProperty
    private var stdoutSocket: Socket?
    @SendableProperty
    private var stderrSocket: Socket?

    init(
        process: inout Command,
        stdio: HostStdio,
        log: Logger?
    ) {
        self.stdio = stdio
        self.log = log

        if stdio.stdin != nil {
            let inPipe = Pipe()
            process.stdin = inPipe.fileHandleForReading
            self.stdinPipe = inPipe
        } else {
            process.stdin = nil
            self.stdinPipe = nil
        }

        if stdio.stdout != nil {
            let outPipe = Pipe()
            process.stdout = outPipe.fileHandleForWriting
            self.stdoutPipe = outPipe
        } else {
            process.stdout = nil
            self.stdoutPipe = nil
        }

        if stdio.stderr != nil {
            let errPipe = Pipe()
            process.stderr = errPipe.fileHandleForWriting
            self.stderrPipe = errPipe
        } else {
            process.stderr = nil
            self.stderrPipe = nil
        }
    }

    func start() throws {
        if let stdinPort = self.stdio.stdin {
            let type = VsockType(
                port: stdinPort,
                cid: VsockType.hostCID
            )
            let stdinSocket = try Socket(type: type)
            try stdinSocket.connect()
            self.stdinSocket = stdinSocket

            try relay(
                readFromFd: stdinSocket.fileDescriptor,
                writeToFd: self.stdinPipe!.fileHandleForWriting.fileDescriptor
            )
        }

        if let stdoutPort = self.stdio.stdout {
            let type = VsockType(
                port: stdoutPort,
                cid: VsockType.hostCID
            )
            let stdoutSocket = try Socket(type: type)
            try stdoutSocket.connect()
            self.stdoutSocket = stdoutSocket

            try relay(
                readFromFd: self.stdoutPipe!.fileHandleForReading.fileDescriptor,
                writeToFd: stdoutSocket.fileDescriptor
            )
        }

        if let stderrPort = self.stdio.stderr {
            let type = VsockType(
                port: stderrPort,
                cid: VsockType.hostCID
            )
            let stderrSocket = try Socket(type: type)
            try stderrSocket.connect()
            self.stderrSocket = stderrSocket

            try relay(
                readFromFd: self.stderrPipe!.fileHandleForReading.fileDescriptor,
                writeToFd: stderrSocket.fileDescriptor
            )
        }
    }

    // NOP
    func resize(size: Terminal.Size) throws {}

    func relay(readFromFd: Int32, writeToFd: Int32) throws {
        let readFrom = OSFile(fd: readFromFd)
        let writeTo = OSFile(fd: writeToFd)
        // `buf` isn't used concurrently.
        nonisolated(unsafe) let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))

        var didCleanup = false
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
            self.log?.error("failed to close write fd for StandardIO relay: \(String(describing:err))")
        }
    }

    func close() throws {
        if let stdin = self.stdinPipe {
            try stdin.fileHandleForWriting.close()
        }
        if let stdout = self.stdoutPipe {
            try stdout.fileHandleForReading.close()
        }
        if let stderr = self.stderrPipe {
            try stderr.fileHandleForReading.close()
        }
    }

    func closeAfterExec() throws {
        if let stdin = self.stdinPipe {
            try stdin.fileHandleForReading.close()
        }
        if let stdout = self.stdoutPipe {
            try stdout.fileHandleForWriting.close()
        }
        if let stderr = self.stderrPipe {
            try stderr.fileHandleForWriting.close()
        }
    }
}
