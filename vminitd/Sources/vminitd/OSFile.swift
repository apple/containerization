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

import Foundation

struct OSFile: Sendable {
    enum IOAction: Equatable {
        case eof
        case again
        case success
        case brokenPipe
        case error(_ errno: Int32)
    }

    private let fd: Int32

    var closed: Bool {
        Foundation.fcntl(fd, F_GETFD) == -1 && errno == EBADF
    }

    var fileDescriptor: Int32 { fd }

    init(fd: Int32) {
        self.fd = fd
    }

    init(handle: FileHandle) {
        self.fd = handle.fileDescriptor
    }

    func close() throws {
        guard Foundation.close(self.fd) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }

    func read(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (read: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesRead: Int = 0
        while true {
            let n = Foundation.read(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesRead),
                buffer.count - bytesRead
            )
            if n == -1 {
                if errno == EAGAIN || errno == EIO {
                    return (bytesRead, .again)
                }
                return (bytesRead, .error(errno))
            }

            if n == 0 {
                return (bytesRead, .eof)
            }

            bytesRead += n
            if bytesRead < buffer.count {
                continue
            }
            return (bytesRead, .success)
        }
    }

    func write(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (wrote: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesWrote: Int = 0
        while true {
            let n = Foundation.write(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesWrote),
                buffer.count - bytesWrote
            )
            if n == -1 {
                if errno == EAGAIN || errno == EIO {
                    return (bytesWrote, .again)
                }
                return (bytesWrote, .error(errno))
            }

            if n == 0 {
                return (bytesWrote, .brokenPipe)
            }

            bytesWrote += n
            if bytesWrote < buffer.count {
                continue
            }
            return (bytesWrote, .success)
        }
    }

    static func pipe() -> (read: Self, write: Self) {
        let pipe = Pipe()
        return (Self(handle: pipe.fileHandleForReading), Self(handle: pipe.fileHandleForWriting))
    }

    static func open(path: String) throws -> Self {
        try open(path: path, mode: O_RDONLY | O_CLOEXEC)
    }

    static func open(path: String, mode: Int32) throws -> Self {
        let fd = Foundation.open(path, mode)
        if fd < 0 {
            throw POSIXError(.init(rawValue: errno)!)
        }
        return Self(fd: fd)
    }
}
