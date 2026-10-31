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

struct OSFile: Sendable {
    enum IOAction: Equatable {
        case eof
        case again
        case success
        case brokenPipe
        case error(_ errno: Int32)
    }

    private let fd: Int32
    private let isSocket: Bool

    var fileDescriptor: Int32 { fd }

    init(fd: Int32, isSocket: Bool = false) {
        self.fd = fd
        self.isSocket = isSocket
    }

    /// vminitd ignores SIGPIPE but test hosts may not, so socket writes use MSG_NOSIGNAL.
    /// Probing once avoids a failing send() on every pipe or PTY write.
    static func writer(fd: Int32) -> OSFile {
        var info = _stat_struct()
        return OSFile(fd: fd, isSocket: fstat(fd, &info) == 0 && info.st_mode & UInt32(S_IFMT) == UInt32(S_IFSOCK))
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
                if errno == EINTR { continue }
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
            let address = buffer.baseAddress?.advanced(by: bytesWrote)
            let remaining = buffer.count - bytesWrote
            let n = isSocket ? send(self.fd, address, remaining, Int32(MSG_NOSIGNAL)) : Foundation.write(self.fd, address, remaining)
            if n == -1 {
                if errno == EINTR { continue }
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
}

#endif
