//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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

#if canImport(Musl)
import Musl
private let _mount = Musl.mount
#elseif canImport(Glibc)
import Glibc
private let _mount = Glibc.mount
#endif

/// Small utility to mount or create new binfmt_misc entries.
public struct Binfmt: Sendable {
    public static let path = "/proc/sys/fs/binfmt_misc"

    public struct Entry {
        public var name: String
        public var type: String
        public var offset: String
        public var magic: String
        public var mask: String
        public var flags: String

        public init(
            name: String,
            type: String = "M",
            offset: String = "",
            magic: String,
            mask: String,
            flags: String = "CF"
        ) {
            self.name = name
            self.type = type
            self.offset = offset
            self.magic = magic
            self.mask = mask
            self.flags = flags
        }

        public static func amd64() -> Self {
            Binfmt.Entry(
                name: "x86_64",
                magic: #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"#,
                mask: #"\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#
            )
        }

        #if os(Linux)
        public func register(binaryPath: String) throws {
            let registration = ":\(self.name):\(self.type):\(self.offset):\(self.magic):\(self.mask):\(binaryPath):\(self.flags)"

            try registration.write(
                to: URL(fileURLWithPath: Binfmt.path).appendingPathComponent("register"),
                atomically: false,
                encoding: .ascii
            )
        }

        public func unregister() throws {
            let data = "-1"
            try data.write(
                to: URL(fileURLWithPath: Binfmt.path).appendingPathComponent(self.name),
                atomically: false,
                encoding: .ascii
            )
        }
        #endif  // os(Linux)
    }

    #if os(Linux)
    /// Crude check to see if /proc/sys/fs/binfmt_misc/register exists.
    public static func mounted() -> Bool {
        FileManager.default.fileExists(atPath: "\(Self.path)/register")
    }

    public static func mount() throws {
        guard _mount("binfmt_misc", Self.path, "binfmt_misc", 0, "") == 0 else {
            throw POSIXError.fromErrno()
        }
    }
    #endif  // os(Linux)
}
