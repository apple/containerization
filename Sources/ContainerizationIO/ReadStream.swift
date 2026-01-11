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

import ContainerizationOS
import Foundation
import NIO

/// `ReadStream` is a utility type for streaming data from a `URL`
/// or `Data` blob.
public class ReadStream {
    public static let bufferSize = Int(1.mib())

    private var _stream: InputStream
    private let buffSize: Int
    private let data: Data?
    private let url: URL?

    public init() {
        _stream = InputStream(data: .init())
        buffSize = Self.bufferSize
        self.data = Data()
        self.url = nil
    }

    public init(url: URL, bufferSize: Int = bufferSize) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.noSuchFileOrDirectory(url)
        }
        guard let stream = InputStream(url: url) else {
            throw Error.failedToCreateStream
        }
        self._stream = stream
        self.buffSize = bufferSize
        self.url = url
        self.data = nil
    }

    public init(data: Data, bufferSize: Int = bufferSize) {
        self._stream = InputStream(data: data)
        self.buffSize = bufferSize
        self.url = nil
        self.data = data
    }

    /// Resets the read stream. This either reassigns
    /// the data buffer or url to a new InputStream internally.
    public func reset() throws {
        self._stream.close()
        if let url = self.url {
            guard let s = InputStream(url: url) else {
                throw Error.failedToCreateStream
            }
            self._stream = s
            return
        }
        let data = self.data ?? Data()
        self._stream = InputStream(data: data)
    }

    /// Get access to an `AsyncStream` of `ByteBuffer`'s from the input source.
    public var stream: AsyncStream<ByteBuffer> {
        AsyncStream { cont in
            self._stream.open()
            defer { self._stream.close() }

            let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: buffSize)

            while true {
                let byteRead = self._stream.read(readBuffer, maxLength: buffSize)
                if byteRead <= 0 {
                    readBuffer.deallocate()
                    cont.finish()
                    break
                } else {
                    let data = Data(bytes: readBuffer, count: byteRead)
                    let buffer = ByteBuffer(bytes: data)
                    cont.yield(buffer)
                }
            }
        }
    }

    /// Get access to an `AsyncStream` of `Data` objects from the input source.
    public var dataStream: AsyncStream<Data> {
        AsyncStream { cont in
            self._stream.open()
            defer { self._stream.close() }

            let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: self.buffSize)
            while true {
                let byteRead = self._stream.read(readBuffer, maxLength: self.buffSize)
                if byteRead <= 0 {
                    readBuffer.deallocate()
                    cont.finish()
                    break
                } else {
                    let data = Data(bytes: readBuffer, count: byteRead)
                    cont.yield(data)
                }
            }
        }
    }
}

extension ReadStream {
    /// Errors that can be encountered while using a `ReadStream`.
    public enum Error: Swift.Error, CustomStringConvertible {
        case failedToCreateStream
        case noSuchFileOrDirectory(_ p: URL)

        public var description: String {
            switch self {
            case .failedToCreateStream:
                return "failed to create stream"
            case .noSuchFileOrDirectory(let p):
                return "no such file or directory: \(p.path)"
            }
        }
    }
}
