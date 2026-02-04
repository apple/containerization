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
import SystemPackage

extension FilePath {
    public static let Separator: String = "/"

    public var bytes: [UInt8] {
        self.withCString { cstr in
            var ptr = cstr
            var rawBytes: [UInt8] = []
            while UInt(bitPattern: ptr) != 0 {
                if ptr.pointee == 0x00 { break }
                rawBytes.append(UInt8(bitPattern: ptr.pointee))
                ptr = ptr.successor()
            }
            return rawBytes
        }
    }

    public var base: String {
        self.lastComponent?.string ?? "/"
    }

    public var dir: FilePath {
        self.removingLastComponent()
    }

    public var url: URL {
        URL(fileURLWithPath: self.string)
    }

    public var items: [String] {
        self.components.map { $0.string }
    }

    public init(_ url: URL) {
        self.init(url.path(percentEncoded: false))
    }

    public init?(_ data: Data) {
        let cstr: String? = data.withUnsafeBytes { (rbp: UnsafeRawBufferPointer) in
            guard let baseAddress = rbp.baseAddress else {
                return nil
            }

            let cString = baseAddress.bindMemory(to: CChar.self, capacity: data.count)
            return String(cString: cString)
        }

        guard let cstr else {
            return nil
        }
        self.init(cstr)
    }

    public func join(_ path: FilePath) -> FilePath {
        self.pushing(path)
    }

    public func join(_ path: String) -> FilePath {
        self.join(FilePath(path))
    }

    public func split() -> (dir: FilePath, base: String) {
        (self.dir, self.base)
    }

    public func clean() -> FilePath {
        self.lexicallyNormalized()
    }

    public static func rel(_ basepath: String, _ targpath: String) -> FilePath {
        let base = FilePath(basepath)
        let targ = FilePath(targpath)

        if base == targ {
            return "."
        }

        let baseComponents = base.items
        let targComponents = targ.items

        var commonPrefix = 0
        while commonPrefix < min(baseComponents.count, targComponents.count)
            && baseComponents[commonPrefix] == targComponents[commonPrefix]
        {
            commonPrefix += 1
        }

        let upCount = baseComponents.count - commonPrefix
        let relComponents = Array(repeating: "..", count: upCount) + targComponents[commonPrefix...]

        return FilePath(relComponents.joined(separator: Self.Separator))
    }
}

extension FileHandle {
    public convenience init?(forWritingTo path: FilePath) {
        self.init(forWritingAtPath: path.description)
    }

    public convenience init?(forReadingAtPath path: FilePath) {
        self.init(forReadingAtPath: path.description)
    }

    public convenience init?(forReadingFrom path: FilePath) {
        self.init(forReadingAtPath: path.description)
    }
}
