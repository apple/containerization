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

// takes a pointer and converts its contents to native endian bytes
public func withUnsafeLittleEndianBytes<T, Result>(of value: T, body: (UnsafeRawBufferPointer) throws -> Result)
    rethrows -> Result
{
    switch Endian {
    case .little:
        return try withUnsafeBytes(of: value) { bytes in
            try body(bytes)
        }
    case .big:
        return try withUnsafeBytes(of: value) { buffer in
            let reversedBuffer = Array(buffer.reversed())
            return try reversedBuffer.withUnsafeBytes { buf in
                try body(buf)
            }
        }
    }
}

public func withUnsafeLittleEndianBuffer<T>(
    of value: UnsafeRawBufferPointer, body: (UnsafeRawBufferPointer) throws -> T
) rethrows -> T {
    switch Endian {
    case .little:
        return try body(value)
    case .big:
        let reversed = Array(value.reversed())
        return try reversed.withUnsafeBytes { buf in
            try body(buf)
        }
    }
}

extension UnsafeRawBufferPointer {
    // loads littleEndian raw data, converts it native endian format and calls UnsafeRawBufferPointer.load
    public func loadLittleEndian<T>(as type: T.Type) -> T {
        switch Endian {
        case .little:
            return self.load(as: T.self)
        case .big:
            let buffer = Array(self.reversed())
            return buffer.withUnsafeBytes { ptr in
                ptr.load(as: T.self)
            }
        }
    }
}

public enum Endianness {
    case little
    case big
}

// returns current endianness
public var Endian: Endianness {
    switch CFByteOrderGetCurrent() {
    case CFByteOrder(CFByteOrderLittleEndian.rawValue):
        return .little
    case CFByteOrder(CFByteOrderBigEndian.rawValue):
        return .big
    default:
        fatalError("impossible")
    }
}
