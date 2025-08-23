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

struct IntegerExtensionsTests {

    @Test func uint8ArrayAllZeros() {
        let allZeroArray: [UInt8] = [0, 0, 0, 0]
        #expect(allZeroArray.allZeros == true)

        let mixedArray: [UInt8] = [0, 1, 0, 0]
        #expect(mixedArray.allZeros == false)

        let emptyArray: [UInt8] = []
        #expect(emptyArray.allZeros == true)

        let nonZeroArray: [UInt8] = [1, 2, 3]
        #expect(nonZeroArray.allZeros == false)
    }

    // MARK: - Bit Manipulation Tests (Actual algorithmic logic)

    @Test func uint64HiLoExtraction() {
        let value: UInt64 = 0x1234_5678_9abc_def0
        #expect(value.lo == 0x9abc_def0)
        #expect(value.hi == 0x1234_5678)

        let maxValue = UInt64.max
        #expect(maxValue.lo == 0xffff_ffff)
        #expect(maxValue.hi == 0xffff_ffff)

        let minValue: UInt64 = 0
        #expect(minValue.lo == 0)
        #expect(minValue.hi == 0)

        let boundaryValue: UInt64 = 0x0000_0001_0000_0000
        #expect(boundaryValue.lo == 0)
        #expect(boundaryValue.hi == 1)
    }

    @Test func uint32HiLoExtraction() {
        let value: UInt32 = 0x1234_5678
        #expect(value.lo == 0x5678)
        #expect(value.hi == 0x1234)

        let maxValue = UInt32.max
        #expect(maxValue.lo == 0xffff)
        #expect(maxValue.hi == 0xffff)

        let minValue: UInt32 = 0
        #expect(minValue.lo == 0)
        #expect(minValue.hi == 0)

        let boundaryValue: UInt32 = 0x0001_0000
        #expect(boundaryValue.lo == 0)
        #expect(boundaryValue.hi == 1)
    }

    // MARK: - File Type Detection (Core business logic)

    @Test func uint16FileTypeDetection() {
        // Test directory detection
        let dirMode: UInt16 = EXT4.FileModeFlag.S_IFDIR.rawValue
        #expect(dirMode.isDir() == true)
        #expect(dirMode.isLink() == false)
        #expect(dirMode.isReg() == false)
        #expect(dirMode.fileType() == EXT4.FileType.directory.rawValue)

        // Test regular file detection
        let regMode: UInt16 = EXT4.FileModeFlag.S_IFREG.rawValue
        #expect(regMode.isDir() == false)
        #expect(regMode.isLink() == false)
        #expect(regMode.isReg() == true)
        #expect(regMode.fileType() == EXT4.FileType.regular.rawValue)

        // Test symbolic link detection
        let linkMode: UInt16 = EXT4.FileModeFlag.S_IFLNK.rawValue
        #expect(linkMode.isDir() == false)
        #expect(linkMode.isLink() == true)
        #expect(linkMode.isReg() == false)
        #expect(linkMode.fileType() == EXT4.FileType.symbolicLink.rawValue)

        // Test character device
        let charMode: UInt16 = EXT4.FileModeFlag.S_IFCHR.rawValue
        #expect(charMode.isDir() == false)
        #expect(charMode.isLink() == false)
        #expect(charMode.isReg() == false)
        #expect(charMode.fileType() == EXT4.FileType.character.rawValue)

        // Test block device
        let blockMode: UInt16 = EXT4.FileModeFlag.S_IFBLK.rawValue
        #expect(blockMode.fileType() == EXT4.FileType.block.rawValue)

        // Test FIFO
        let fifoMode: UInt16 = EXT4.FileModeFlag.S_IFIFO.rawValue
        #expect(fifoMode.fileType() == EXT4.FileType.fifo.rawValue)

        // Test socket
        let socketMode: UInt16 = EXT4.FileModeFlag.S_IFSOCK.rawValue
        #expect(socketMode.fileType() == EXT4.FileType.socket.rawValue)

        // Test unknown type
        let unknownMode: UInt16 = 0x0000
        #expect(unknownMode.fileType() == EXT4.FileType.unknown.rawValue)
    }

    @Test func uint16FileTypeWithPermissionBits() {
        // Test that file type detection works correctly when permission bits are set
        let dirWithPerms: UInt16 = EXT4.FileModeFlag.S_IFDIR.rawValue | 0o755
        #expect(dirWithPerms.isDir() == true)
        #expect(dirWithPerms.fileType() == EXT4.FileType.directory.rawValue)

        let regWithPerms: UInt16 = EXT4.FileModeFlag.S_IFREG.rawValue | 0o644
        #expect(regWithPerms.isReg() == true)
        #expect(regWithPerms.fileType() == EXT4.FileType.regular.rawValue)

        let linkWithPerms: UInt16 = EXT4.FileModeFlag.S_IFLNK.rawValue | 0o777
        #expect(linkWithPerms.isLink() == true)
        #expect(linkWithPerms.fileType() == EXT4.FileType.symbolicLink.rawValue)
    }

    @Test func uint16FileTypeMaskingLogic() {
        // Test the bit masking logic specifically
        let typeMask = EXT4.FileModeFlag.TypeMask.rawValue  // 0xF000

        // Test directory type (0x4000) with permission bits and special bits
        let dirType = EXT4.FileModeFlag.S_IFDIR.rawValue  // 0x4000
        let dirWithExtraBits = dirType | 0o755 | EXT4.FileModeFlag.S_ISUID.rawValue  // Add setuid bit
        #expect((dirWithExtraBits & typeMask) == dirType)
        #expect(dirWithExtraBits.isDir() == true)

        // Test regular file type (0x8000) with permission bits and special bits
        let regType = EXT4.FileModeFlag.S_IFREG.rawValue  // 0x8000
        let regWithExtraBits = regType | 0o644 | EXT4.FileModeFlag.S_ISGID.rawValue  // Add setgid bit
        #expect((regWithExtraBits & typeMask) == regType)
        #expect(regWithExtraBits.isReg() == true)
    }
}
