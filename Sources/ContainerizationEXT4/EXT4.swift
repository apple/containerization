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

/**
 ```
# EXT4 Filesystem Layout

 The EXT4 filesystem divides the disk into an upfront metadata section followed by several logical groups known as block groups. The
 metadata section looks like this:

    +--------------------------+
    |    Boot Sector (1024)    |
    +--------------------------+
    |    Superblock (1024)     |
    +--------------------------+
    |      Empty (2048)        |
    +--------------------------+
    |                          |
    | [Block Group Descriptors]|
    |                          |
    | - Free/used block bitmap |
    | - Free/used inode bitmap |
    | - Inode table pointer    |
    | - Other metadata         |
    |                          |
    +--------------------------+

 ## Block Groups

 Each block group optionally stores a copy of the superblock and group descriptor table for disaster recovery.
 The rest of the block group comprises of data blocks. The size of each block group is dynamically decided
 while formatting, based on total amount of space available on the disk.

    +--------------------------+
    |      Block Group 0       |
    |    +------------------+  |
    |    |   Super Block    |  |
    |    +------------------+  |
    |    |   Group Desc.    |  |
    |    +------------------+  |
    |    |   Data Blocks    |  |
    |    |                  |  |
    |    +------------------+  |
    +--------------------------+
    |      Block Group 1       |
    |    +------------------+  |
    |    |   Super Block    |  |
    |    +------------------+  |
    |    |   Group Desc.    |  |
    |    +------------------+  |
    |    |   Data Blocks    |  |
    |    |                  |  |
    |    +------------------+  |
    +--------------------------+
    |           ...            |
    +--------------------------+
    |      Block Group N       |
    |    +------------------+  |
    |    |   Super Block    |  |
    |    +------------------+  |
    |    |   Group Desc.    |  |
    |    +------------------+  |
    |    |   Data Blocks    |  |
    |    |                  |  |
    |    +------------------+  |
    +--------------------------+

 The descriptor for each block group contain the following information:

 - Block Bitmap
 - Inode Bitmap
 - Pointer to Inode Table
 - other metadata such as used block count, num. dirs etc.

 ### Block Bitmap

 A sequence of bits, where each bit represents a block in the block group.

    1: In use block
    0: Free block

    +---------------+---------------+
    |             Block             |
    |            Bitmap             |
    +---------------+---------------+
    | 1   0   1   0   1   1   0   0 |
    +---------------+---------------+
    |   |   |   |   |   |   |   |
    |   |   |   |   |   |   |   |
    v   v   v   v   v   v   v   v
    +---+---+---+---+---+---+---+---+
    | B |   | B |   | B | B |   |   |
    +---+---+---+---+---+---+---+---+

 Whenever a file is created, free data blocks are identified by using this table.
 When it is deleted, the corresponding data blocks are marked as free.

 ### Inode Bitmap

 A sequence of bits, where each bit represents a inode in the block group. Since
 inodes per group is a fixed number, this bitmap is made to be of sufficient length
 to accommodate that many inodes

    1: In use inode
    0: Free inode

    +---------------+---------------+
    |             Inode             |
    |            Bitmap             |
    +---------------+---------------+
    | 1   0   1   0   1   1   0   0 |
    +---------------+---------------+
    |   |   |   |   |   |   |   |
    |   |   |   |   |   |   |   |
    v   v   v   v   v   v   v   v
    +---+---+---+---+---+---+---+---+
    | I |   | I |   | I | I |   |   |
    +---+---+---+---+---+---+---+---+

 ## Inode table

 Inode table provides a mapping from Inode -> Data blocks. In this implementation, inode size is set to 256 bytes.
 Inode table uses extents to efficiently describe the mapping.

    +-----------------------+
    |      Inode Table      |
    +-----------------------+
    | Inode | Metadata      |
    +-------+---------------+
    |   1   | permissions   |
    |       | size          |
    |       | user ID       |
    |       | group ID      |
    |       | timestamps    |
    |       | block         |
    |       | blocks count  |
    +-------+---------------+
    |   2   | ...           |
    +-------+---------------+
    |  ...  | ...           |
    +-------+---------------+

 The length of `block` field in the inode table is 60 bytes. This field contains an extent tree
 that holds information about ranges of blocks used by the file. For smaller files, the entire extent
 tree can be stored within this field.

    +-----------------------+
    |        Inode          |
    +-----------------------+
    | Metadata              |
    +-----------------------+
    | Extent Tree           |
    | +-------------------+ |
    | | Extent Leaf Node  | |
    | +-------------------+ |
    | | - Start Block     | |
    | | - Block Count     | |
    | | - ...             | |
    | +-------------------+ |
    +-----------------------+

 For larger files which span across multiple non-contiguous blocks, extent tree's root points to extent
 blocks, which in-turn point to the blocks used by the file

    +-----------------------+
    | Extent Tree           |
    | +-------------------+ |
    | | Extent Root       | |
    | +-------------------+ |
    | | - Pointers to     | |
    | |   Extent Blocks   | |
    | +-------------------+ |
    +-----------------------+
          |
          v
    +-----------------------+
    |     Extent Block      |
    +-----------------------+
    | +-------------------+ |
    | | Extent Leaf Node  | |
    | +-------------------+ |
    | | - Start Block     | |
    | | - Block Count     | |
    | | - ...             | |
    | +-------------------+ |
    | +-------------------+ |
    | | Extent Leaf Node  | |
    | +-------------------+ |
    | | - Start Block     | |
    | | - Block Count     | |
    | | - ...             | |
    | +-------------------+ |
    +-----------------------+

 ## Directory entries

 The data blocks for directory inodes point to a list of directory entrees. Each entry
 consists of only a name and inode number. The name and inode number correspond to the
 name and inode number of the children of the directory

    +-------------------------+
    |     Directory Entry     |
    +-------------------------+
    | inode | rec_len | name  |
    +-------------------------+
    |   2   |    1    |  "."  |
    +-------------------------+
    |     Directory Entry     |
    +-------------------------+
    | inode | rec_len | name  |
    +-------------------------+
    |   1   |    2    | ".."  |
    +-------------------------+
    |     Directory Entry     |
    +-------------------------+
    | inode | rec_len | name  |
    +-------------------------+
    |  11   |   10    | lost& |
    |       |         | found |
    +-------------------------+

More details can be found here https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout

```
*/

/// A type for interacting with ext4 file systems.
///
/// The `Ext4` class provides functionality to read the superblock of an existing ext4 block device
/// and format a new block device with the ext4 file system.
///
/// Usage:
/// - To read the superblock of an existing ext4 block device, create an instance of `Ext4` with the
///   path to the block device
/// - To format a new block device with ext4, create an instance of `Ext4.Formatter` with the path to the block
///   device and call the `close()` method.
///
/// Example 1: Read an existing block device
/// ```swift
///  let blockDevice = URL(filePath: "/dev/sdb")
///  // succeeds if a valid ext4 fs is found at path
///  let ext4 = try Ext4(blockDevice: blockDevice)
///  print("Block size: \(ext4.blockSize)")
///  print("Total size: \(ext4.size)")
///
///  // Reading the superblock
///  let superblock = ext4.superblock
///  print("Superblock information:")
///  print("Total blocks: \(superblock.blocksCountLow)")
/// ```
///
/// Example 2: Format a new block device (Refer [`EXT4.Formatter`](x-source-tag://EXT4.Formatter) for more info)
/// ```swift
///  let devicePath = URL(filePath: "/dev/sdc")
///  let formatter = try EXT4.Formatter(devicePath, blockSize: 4096)
///  try formatter.close()
/// ```
public enum EXT4 {
    public static let SuperBlockMagic: UInt16 = 0xef53

    static let ExtentHeaderMagic: UInt16 = 0xf30a
    static let XAttrHeaderMagic: UInt32 = 0xea02_0000

    static let DefectiveBlockInode: InodeNumber = 1
    static let RootInode: InodeNumber = 2
    static let FirstInode: InodeNumber = 11
    static let LostAndFoundInode: InodeNumber = 11

    static let InodeActualSize: UInt32 = 160  // 160 bytes used by metadata
    static let InodeExtraSize: UInt32 = 96  // 96 bytes for inline xattrs
    static let InodeSize: UInt32 = UInt32(MemoryLayout<Inode>.size)  // 256 bytes. This is the max size of an inode
    static let XattrInodeHeaderSize: UInt32 = 4
    static let XattrBlockHeaderSize: UInt32 = 32
    static let ExtraIsize: UInt16 = UInt16(InodeActualSize) - 128

    static let MaxLinks: UInt32 = 65000
    static let MaxBlocksPerExtent: UInt32 = 0x8000
    static let MaxFileSize: UInt64 = 128.gib()
    static let SuperBlockOffset: UInt64 = 1024
}

extension EXT4 {
    // `EXT4` errors.
    public enum Error: Swift.Error, CustomStringConvertible, Sendable, Equatable {
        case notFound(_ path: String)
        case couldNotReadSuperBlock(_ path: String, _ offset: UInt64, _ size: Int)
        case invalidSuperBlock
        case deepExtentsUnimplemented
        case invalidExtents
        case invalidXattrEntry
        case couldNotReadBlock(_ block: UInt32)
        case invalidPathEncoding(_ path: String)
        case couldNotReadInode(_ inode: UInt32)
        case couldNotReadGroup(_ group: UInt32)
        public var description: String {
            switch self {
            case .notFound(let path):
                return "file at path \(path) not found"
            case .couldNotReadSuperBlock(let path, let offset, let size):
                return "could not read \(size) bytes of superblock from \(path) at offset \(offset)"
            case .invalidSuperBlock:
                return "not a valid EXT4 superblock"
            case .deepExtentsUnimplemented:
                return "deep extents are not supported"
            case .invalidExtents:
                return "extents invalid or corrupted"
            case .invalidXattrEntry:
                return "invalid extended attribute entry"
            case .couldNotReadBlock(let block):
                return "could not read block \(block)"
            case .invalidPathEncoding(let path):
                return "path encoding for '\(path)' is invalid, must be ascii or utf8"
            case .couldNotReadInode(let inode):
                return "could not read inode \(inode)"
            case .couldNotReadGroup(let group):
                return "could not read group descriptor \(group)"
            }
        }
    }
}
