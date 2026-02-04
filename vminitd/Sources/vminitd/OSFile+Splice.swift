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

extension OSFile {
    struct SpliceFile: Sendable {
        fileprivate var file: OSFile
        fileprivate var offset: Int
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
            self.offset = 0
        }

        init(handle: FileHandle) {
            self.file = OSFile(handle: handle)
            self.offset = 0
        }

        init(from: OSFile, withOffset: Int = 0) {
            self.file = from
            self.offset = withOffset
        }

        func close() throws {
            try self.file.close()
        }
    }

    static func splice(from: inout SpliceFile, to: inout SpliceFile, count: Int = 1 << 16) throws -> (read: Int, wrote: Int, action: IOAction) {
        let fromOffset = from.offset
        let toOffset = to.offset

        while true {
            while (from.offset - to.offset) < count {
                let toRead = count - (from.offset - to.offset)
                let bytesRead = Foundation.splice(from.fileDescriptor, nil, to.writer, nil, toRead, UInt32(bitPattern: SPLICE_F_MOVE | SPLICE_F_NONBLOCK))
                if bytesRead == -1 {
                    if errno != EAGAIN && errno != EIO {
                        throw POSIXError(.init(rawValue: errno)!)
                    }
                    break
                }
                if bytesRead == 0 {
                    return (0, 0, .eof)
                }
                from.offset += bytesRead
                if bytesRead < toRead {
                    break
                }
            }
            if from.offset == to.offset {
                return (from.offset - fromOffset, to.offset - toOffset, .success)
            }
            while to.offset < from.offset {
                let toWrite = from.offset - to.offset
                let bytesWrote = Foundation.splice(to.reader, nil, to.fileDescriptor, nil, toWrite, UInt32(bitPattern: SPLICE_F_MOVE | SPLICE_F_NONBLOCK))
                if bytesWrote == -1 {
                    if errno != EAGAIN && errno != EIO {
                        throw POSIXError(.init(rawValue: errno)!)
                    }
                    break
                }
                to.offset += bytesWrote
                if bytesWrote == 0 {
                    return (from.offset - fromOffset, to.offset - toOffset, .brokenPipe)
                }
                if bytesWrote < toWrite {
                    break
                }
            }
        }
    }
}
