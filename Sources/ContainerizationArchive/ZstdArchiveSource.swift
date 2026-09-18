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

import CArchive
import Foundation
import libzstd

/// Decompresses a zstd archive for libarchive, so its contents are never written to disk.
final class ZstdArchiveSource {
    private let source: FileHandle
    private let stream: OpaquePointer
    private let input: UnsafeMutableRawBufferPointer
    private let output: UnsafeMutableRawBufferPointer

    private var inputCount = 0
    private var inputOffset = 0
    private var sourceExhausted = false

    private init(source: FileHandle, stream: OpaquePointer) {
        self.source = source
        self.stream = stream
        self.input = .allocate(byteCount: ZSTD_DStreamInSize(), alignment: MemoryLayout<UInt8>.alignment)
        self.output = .allocate(byteCount: ZSTD_DStreamOutSize(), alignment: MemoryLayout<UInt8>.alignment)
    }

    deinit {
        ZSTD_freeDStream(stream)
        input.deallocate()
        output.deallocate()
        try? source.close()
    }

    /// Opens `archive` on `source`.
    static func open(archive: OpaquePointer?, source: FileHandle) -> CInt {
        guard let stream = ZSTD_createDStream(), ZSTD_isError(ZSTD_initDStream(stream)) == 0 else {
            try? source.close()
            return ARCHIVE_FATAL
        }
        let client = ZstdArchiveSource(source: source, stream: stream)

        let opaque = Unmanaged.passRetained(client).toOpaque()
        guard
            archive_read_set_callback_data(archive, opaque) == ARCHIVE_OK,
            archive_read_set_read_callback(archive, readCallback) == ARCHIVE_OK,
            archive_read_set_close_callback(archive, closeCallback) == ARCHIVE_OK
        else {
            Unmanaged<ZstdArchiveSource>.fromOpaque(opaque).release()
            return ARCHIVE_FATAL
        }
        return archive_read_open1(archive)
    }

    /// Decompresses the next block, returning its size, 0 at end of input, or -1 on error.
    fileprivate func next(_ archive: OpaquePointer?, into buffer: UnsafeMutablePointer<UnsafeRawPointer?>?) -> la_ssize_t {
        buffer?.pointee = UnsafeRawPointer(output.baseAddress)

        var bytesProduced = 0
        while bytesProduced == 0 {
            if inputOffset == inputCount && !sourceExhausted {
                guard let bytesRead = readSource() else {
                    let code = errno
                    archive_set_error_wrapper(archive, code, "failed to read zstd input: \(String(cString: strerror(code)))")
                    return -1
                }
                sourceExhausted = bytesRead == 0
                inputCount = bytesRead
                inputOffset = 0
            }

            var out = ZSTD_outBuffer(dst: output.baseAddress, size: output.count, pos: bytesProduced)
            var used = ZSTD_inBuffer(src: input.baseAddress, size: inputCount, pos: inputOffset)
            let remainder = ZSTD_decompressStream(stream, &out, &used)
            inputOffset = used.pos
            bytesProduced = out.pos
            guard ZSTD_isError(remainder) == 0 else {
                archive_set_error_wrapper(archive, EIO, "failed to decompress zstd input: \(String(cString: ZSTD_getErrorName(remainder)))")
                return -1
            }

            if bytesProduced == 0 && sourceExhausted {
                // A remainder here means the input ended early.
                guard remainder == 0 else {
                    archive_set_error_wrapper(archive, EIO, "zstd input ended before the end of the stream")
                    return -1
                }
                return 0
            }
        }
        return la_ssize_t(bytesProduced)
    }

    private func readSource() -> Int? {
        while true {
            let bytesRead = read(source.fileDescriptor, input.baseAddress, input.count)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            return bytesRead
        }
    }

    fileprivate static func unwrap(_ clientData: UnsafeMutableRawPointer?) -> ZstdArchiveSource? {
        guard let clientData else { return nil }
        return Unmanaged<ZstdArchiveSource>.fromOpaque(clientData).takeUnretainedValue()
    }
}

private let readCallback:
    @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>?
    ) -> la_ssize_t = { archive, clientData, buffer in
        guard let client = ZstdArchiveSource.unwrap(clientData) else { return -1 }
        return client.next(archive, into: buffer)
    }

private let closeCallback: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> CInt = { _, clientData in
    guard let clientData else { return ARCHIVE_OK }
    Unmanaged<ZstdArchiveSource>.fromOpaque(clientData).release()
    return ARCHIVE_OK
}
