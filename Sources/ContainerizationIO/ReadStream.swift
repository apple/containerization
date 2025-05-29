//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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

public class ReadStream {
    public static let bufferSize = Int(1.mib())

    private var _stream: InputStream
    private let _buffSize: Int
    private let _data: Data?
    private let _url: URL?

    public init() {
        _stream = InputStream(data: .init())
        _buffSize = Self.bufferSize
        self._data = Data()
        self._url = nil
    }

    public init(url: URL, bufferSize: Int = bufferSize) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.noSuchFileOrDirectory(url)
        }
        guard let stream = InputStream(url: url) else {
            throw Error.failedToCreateStream
        }
        self._stream = stream
        self._buffSize = bufferSize
        self._url = url
        self._data = nil
    }

    public init(data: Data, bufferSize: Int = bufferSize) {
        self._stream = InputStream(data: data)
        self._buffSize = bufferSize
        self._url = nil
        self._data = data
    }

    public func reset() throws {
        self._stream.close()
        if let url = self._url {
            guard let s = InputStream(url: url) else {
                throw Error.failedToCreateStream
            }
            self._stream = s
            return
        }
        let data = self._data ?? Data()
        self._stream = InputStream(data: data)
    }

    public var stream: AsyncStream<ByteBuffer> {
        AsyncStream { cont in
            self._stream.open()
            defer { self._stream.close() }

            let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: _buffSize)

            while true {
                let byteRead = self._stream.read(readBuffer, maxLength: _buffSize)
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

    public var dataStream: AsyncStream<Data> {
        AsyncStream { cont in
            self._stream.open()
            defer { self._stream.close() }

            let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: self._buffSize)
            while true {
                let byteRead = self._stream.read(readBuffer, maxLength: self._buffSize)
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
    enum Error: Swift.Error, CustomStringConvertible {
        case failedToCreateStream
        case noSuchFileOrDirectory(_ p: URL)

        var description: String {
            switch self {
            case .failedToCreateStream:
                return "failed to create stream"
            case .noSuchFileOrDirectory(let p):
                return "no such file or directory: \(p.path)"
            }
        }
    }
}
