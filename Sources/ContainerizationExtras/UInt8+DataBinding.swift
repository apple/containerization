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

extension ArraySlice<UInt8> {
    package func hexEncodedString() -> String {
        self.map { String(format: "%02hhx", $0) }.joined()
    }
}

extension [UInt8] {
    package func hexEncodedString() -> String {
        self.map { String(format: "%02hhx", $0) }.joined()
    }

    package mutating func bind<T>(as type: T.Type, offset: Int = 0, size: Int? = nil) -> UnsafeMutablePointer<T>? {
        guard self.count >= (size ?? MemoryLayout<T>.size) + offset else {
            return nil
        }

        return self.withUnsafeMutableBytes { $0.baseAddress?.advanced(by: offset).assumingMemoryBound(to: T.self) }
    }

    package mutating func copyIn<T>(as type: T.Type, value: T, offset: Int = 0, size: Int? = nil) -> Int? {
        let size = size ?? MemoryLayout<T>.size
        guard self.count >= size - offset else {
            return nil
        }

        return self.withUnsafeMutableBytes {
            $0.baseAddress?.advanced(by: offset).assumingMemoryBound(to: T.self).pointee = value
            return offset + MemoryLayout<T>.size
        }
    }

    package mutating func copyOut<T>(as type: T.Type, offset: Int = 0, size: Int? = nil) -> (Int, T)? {
        guard self.count >= (size ?? MemoryLayout<T>.size) - offset else {
            return nil
        }

        return self.withUnsafeMutableBytes {
            guard let value = $0.baseAddress?.advanced(by: offset).assumingMemoryBound(to: T.self).pointee else {
                return nil
            }
            return (offset + MemoryLayout<T>.size, value)
        }
    }

    package mutating func copyIn(buffer: [UInt8], offset: Int = 0) -> Int? {
        guard offset + buffer.count <= self.count else {
            return nil
        }

        self[offset..<offset + buffer.count] = buffer[0..<buffer.count]
        return offset + buffer.count
    }

    package mutating func copyOut(buffer: inout [UInt8], offset: Int = 0) -> Int? {
        guard offset + buffer.count <= self.count else {
            return nil
        }

        buffer[0..<buffer.count] = self[offset..<offset + buffer.count]
        return offset + buffer.count
    }
}
