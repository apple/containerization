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
import LCShim

extension OSFile {
    struct SpliceFile: Sendable {
        fileprivate var file: OSFile
        fileprivate var pendingBytes = 0
        fileprivate let pipe = Pipe()

        var fileDescriptor: Int32 {
            file.fileDescriptor
        }

        var reader: Int32 {
            pipe.fileHandleForReading.fileDescriptor
        }

        var writer: Int32 {
            pipe.fileHandleForWriting.fileDescriptor
        }

        init(fd: Int32) {
            self.file = OSFile(fd: fd)
        }

        init(handle: FileHandle) {
            self.file = OSFile(handle: handle)
        }

        init(from: OSFile) {
            self.file = from
        }

        func close() throws {
            try self.file.close()
        }
    }

    static func splice(from: inout SpliceFile, to: inout SpliceFile, count: Int = 1 << 16) throws -> (read: Int, wrote: Int, action: IOAction) {
        guard count > 0 else { return (0, 0, .success) }
        var readBytes = 0
        var writtenBytes = 0

        while true {
            // Drain this direction's buffered data before reading more or reporting EOF.
            while to.pendingBytes > 0 {
                let written = LCShim.splice(to.reader, nil, to.fileDescriptor, nil, to.pendingBytes, UInt32(bitPattern: LCShim.SPLICE_F_MOVE | LCShim.SPLICE_F_NONBLOCK))
                if written == -1 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EIO {
                        return (readBytes, writtenBytes, .again)
                    }
                    throw POSIXError(.init(rawValue: errno)!)
                }
                if written == 0 {
                    return (readBytes, writtenBytes, .brokenPipe)
                }
                to.pendingBytes -= written
                writtenBytes += written
            }

            let read = LCShim.splice(from.fileDescriptor, nil, to.writer, nil, count, UInt32(bitPattern: LCShim.SPLICE_F_MOVE | LCShim.SPLICE_F_NONBLOCK))
            if read == -1 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EIO {
                    return (readBytes, writtenBytes, .again)
                }
                throw POSIXError(.init(rawValue: errno)!)
            }
            if read == 0 {
                return (readBytes, writtenBytes, .eof)
            }
            to.pendingBytes += read
            readBytes += read
        }
    }
}

#endif
