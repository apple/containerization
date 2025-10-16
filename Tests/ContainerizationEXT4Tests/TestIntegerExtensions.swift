//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
import Testing

@testable import ContainerizationEXT4

struct TestIntegerExtensions {
    @Test func testUInt64Extensions() {
        let value: UInt64 = 0x1234_5678_abcd_ef01

        #expect(value.lo == 0xabcd_ef01)
        #expect(value.hi == 0x1234_5678)

        let result1 = value - UInt32(100)
        #expect(result1 == value - 100)

        let result2 = value % UInt32(256)
        #expect(result2 == value % 256)

        let result3 = value / UInt32(256)
        #expect(result3 == UInt32((value / 256).lo))

        let result4 = value * UInt32(2)
        #expect(result4 == value * 2)

        let result5 = value * Int(3)
        #expect(result5 == value * 3)
    }

    @Test func testUInt32Extensions() {
        let value: UInt32 = 0x1234_5678

        #expect(value.lo == 0x5678)
        #expect(value.hi == 0x1234)

        let result1 = value + 100
        #expect(result1 == value + UInt32(100))

        let result2 = value - 50
        #expect(result2 == value - UInt32(50))

        let result3 = value / 4
        #expect(result3 == value / UInt32(4))

        let result4 = value - UInt16(10)
        #expect(result4 == value - UInt32(10))

        let result5 = value * 2
        #expect(result5 == Int(value) * 2)
    }

    @Test func testIntExtensions() {
        let value: Int = 100

        let result1: Int = value + UInt32(50)
        #expect(result1 == 150)

        let result2: UInt32 = value + UInt32(25)
        #expect(result2 == 125)
    }

    @Test func testUInt16FileModeExtensions() {
        let dirMode: UInt16 = EXT4.FileModeFlag.S_IFDIR.rawValue | 0o755
        let regMode: UInt16 = EXT4.FileModeFlag.S_IFREG.rawValue | 0o644
        let linkMode: UInt16 = EXT4.FileModeFlag.S_IFLNK.rawValue | 0o777
        let chrMode: UInt16 = EXT4.FileModeFlag.S_IFCHR.rawValue | 0o600
        let blkMode: UInt16 = EXT4.FileModeFlag.S_IFBLK.rawValue | 0o600
        let fifoMode: UInt16 = EXT4.FileModeFlag.S_IFIFO.rawValue | 0o644
        let sockMode: UInt16 = EXT4.FileModeFlag.S_IFSOCK.rawValue | 0o644
        let unknownMode: UInt16 = 0o755

        #expect(dirMode.isDir())
        #expect(!dirMode.isReg())
        #expect(!dirMode.isLink())

        #expect(regMode.isReg())
        #expect(!regMode.isDir())
        #expect(!regMode.isLink())

        #expect(linkMode.isLink())
        #expect(!linkMode.isDir())
        #expect(!linkMode.isReg())

        #expect(dirMode.fileType() == EXT4.FileType.directory.rawValue)
        #expect(regMode.fileType() == EXT4.FileType.regular.rawValue)
        #expect(linkMode.fileType() == EXT4.FileType.symbolicLink.rawValue)
        #expect(chrMode.fileType() == EXT4.FileType.character.rawValue)
        #expect(blkMode.fileType() == EXT4.FileType.block.rawValue)
        #expect(fifoMode.fileType() == EXT4.FileType.fifo.rawValue)
        #expect(sockMode.fileType() == EXT4.FileType.socket.rawValue)
        #expect(unknownMode.fileType() == EXT4.FileType.unknown.rawValue)
    }

    @Test func testUInt8ArrayExtensions() {
        let allZeros: [UInt8] = [0, 0, 0, 0]
        let notAllZeros: [UInt8] = [0, 1, 0, 0]
        let noZeros: [UInt8] = [1, 2, 3, 4]

        #expect(allZeros.allZeros)
        #expect(!notAllZeros.allZeros)
        #expect(!noZeros.allZeros)

        let empty: [UInt8] = []
        #expect(empty.allZeros)
    }
}
