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

//  swiftlint:disable large_tuple

import Foundation

extension EXT4 {
    public struct SuperBlock {
        public var inodesCount: UInt32 = 0
        public var blocksCountLow: UInt32 = 0
        public var rootBlocksCountLow: UInt32 = 0
        public var freeBlocksCountLow: UInt32 = 0
        public var freeInodesCount: UInt32 = 0
        public var firstDataBlock: UInt32 = 0
        public var logBlockSize: UInt32 = 0
        public var logClusterSize: UInt32 = 0
        public var blocksPerGroup: UInt32 = 0
        public var clustersPerGroup: UInt32 = 0
        public var inodesPerGroup: UInt32 = 0
        public var mtime: UInt32 = 0
        public var wtime: UInt32 = 0
        public var mountCount: UInt16 = 0
        public var maxMountCount: UInt16 = 0
        public var magic: UInt16 = 0
        public var state: UInt16 = 0
        public var errors: UInt16 = 0
        public var minorRevisionLevel: UInt16 = 0
        public var lastCheck: UInt32 = 0
        public var checkInterval: UInt32 = 0
        public var creatorOS: UInt32 = 0
        public var revisionLevel: UInt32 = 0
        public var defaultReservedUid: UInt16 = 0
        public var defaultReservedGid: UInt16 = 0
        public var firstInode: UInt32 = 0
        public var inodeSize: UInt16 = 0
        public var blockGroupNr: UInt16 = 0
        public var featureCompat: UInt32 = 0
        public var featureIncompat: UInt32 = 0
        public var featureRoCompat: UInt32 = 0
        public var uuid:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        public var volumeName:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        public var lastMounted:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        public var algorithmUsageBitmap: UInt32 = 0
        public var preallocBlocks: UInt8 = 0
        public var preallocDirBlocks: UInt8 = 0
        public var reservedGdtBlocks: UInt16 = 0
        public var journalUUID:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        public var journalInum: UInt32 = 0
        public var journalDev: UInt32 = 0
        public var lastOrphan: UInt32 = 0
        public var hashSeed: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        public var defHashVersion: UInt8 = 0
        public var journalBackupType: UInt8 = 0
        public var descSize: UInt16 = UInt16(MemoryLayout<GroupDescriptor>.size)
        public var defaultMountOpts: UInt32 = 0
        public var firstMetaBg: UInt32 = 0
        public var mkfsTime: UInt32 = 0
        public var journalBlocks:
            (
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0
            )
        public var blocksCountHigh: UInt32 = 0
        public var rBlocksCountHigh: UInt32 = 0
        public var freeBlocksCountHigh: UInt32 = 0
        public var minExtraIsize: UInt16 = 0
        public var wantExtraIsize: UInt16 = 0
        public var flags: UInt32 = 0
        public var raidStride: UInt16 = 0
        public var mmpInterval: UInt16 = 0
        public var mmpBlock: UInt64 = 0
        public var raidStripeWidth: UInt32 = 0
        public var logGroupsPerFlex: UInt8 = 0
        public var checksumType: UInt8 = 0
        public var reservedPad: UInt16 = 0
        public var kbytesWritten: UInt64 = 0
        public var snapshotInum: UInt32 = 0
        public var snapshotID: UInt32 = 0
        public var snapshotRBlocksCount: UInt64 = 0
        public var snapshotList: UInt32 = 0
        public var errorCount: UInt32 = 0
        public var firstErrorTime: UInt32 = 0
        public var firstErrorInode: UInt32 = 0
        public var firstErrorBlock: UInt64 = 0
        public var firstErrorFunc:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        public var firstErrorLine: UInt32 = 0
        public var lastErrorTime: UInt32 = 0
        public var lastErrorInode: UInt32 = 0
        public var lastErrorLine: UInt32 = 0
        public var lastErrorBlock: UInt64 = 0
        public var lastErrorFunc:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        public var mountOpts:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        public var userQuotaInum: UInt32 = 0
        public var groupQuotaInum: UInt32 = 0
        public var overheadBlocks: UInt32 = 0
        public var backupBgs: (UInt32, UInt32) = (0, 0)
        public var encryptAlgos: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        public var encryptPwSalt:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        public var lpfInode: UInt32 = 0
        public var projectQuotaInum: UInt32 = 0
        public var checksumSeed: UInt32 = 0
        public var wtimeHigh: UInt8 = 0
        public var mtimeHigh: UInt8 = 0
        public var mkfsTimeHigh: UInt8 = 0
        public var lastcheckHigh: UInt8 = 0
        public var firstErrorTimeHigh: UInt8 = 0
        public var lastErrorTimeHigh: UInt8 = 0
        public var pad: (UInt8, UInt8) = (0, 0)
        public var reserved:
            (
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        public var checksum: UInt32 = 0
    }

    struct CompatFeature {
        let rawValue: UInt32

        static let dirPrealloc = CompatFeature(rawValue: 0x1)
        static let imagicInodes = CompatFeature(rawValue: 0x2)
        static let hasJournal = CompatFeature(rawValue: 0x4)
        static let extAttr = CompatFeature(rawValue: 0x8)
        static let resizeInode = CompatFeature(rawValue: 0x10)
        static let dirIndex = CompatFeature(rawValue: 0x20)
        static let lazyBg = CompatFeature(rawValue: 0x40)
        static let excludeInode = CompatFeature(rawValue: 0x80)
        static let excludeBitmap = CompatFeature(rawValue: 0x100)
        static let sparseSuper2 = CompatFeature(rawValue: 0x200)
    }

    struct IncompatFeature {
        let rawValue: UInt32

        static let compression = IncompatFeature(rawValue: 0x1)
        static let filetype = IncompatFeature(rawValue: 0x2)
        static let recover = IncompatFeature(rawValue: 0x4)
        static let journalDev = IncompatFeature(rawValue: 0x8)
        static let metaBg = IncompatFeature(rawValue: 0x10)
        static let extents = IncompatFeature(rawValue: 0x40)
        static let bit64 = IncompatFeature(rawValue: 0x80)
        static let mmp = IncompatFeature(rawValue: 0x100)
        static let flexBg = IncompatFeature(rawValue: 0x200)
        static let eaInode = IncompatFeature(rawValue: 0x400)
        static let dirdata = IncompatFeature(rawValue: 0x1000)
        static let csumSeed = IncompatFeature(rawValue: 0x2000)
        static let largedir = IncompatFeature(rawValue: 0x4000)
        static let inlineData = IncompatFeature(rawValue: 0x8000)
        static let encrypt = IncompatFeature(rawValue: 0x10000)
    }

    struct RoCompatFeature {
        let rawValue: UInt32

        static let sparseSuper = RoCompatFeature(rawValue: 0x1)
        static let largeFile = RoCompatFeature(rawValue: 0x2)
        static let btreeDir = RoCompatFeature(rawValue: 0x4)
        static let hugeFile = RoCompatFeature(rawValue: 0x8)
        static let gdtCsum = RoCompatFeature(rawValue: 0x10)
        static let dirNlink = RoCompatFeature(rawValue: 0x20)
        static let extraIsize = RoCompatFeature(rawValue: 0x40)
        static let hasSnapshot = RoCompatFeature(rawValue: 0x80)
        static let quota = RoCompatFeature(rawValue: 0x100)
        static let bigalloc = RoCompatFeature(rawValue: 0x200)
        static let metadataCsum = RoCompatFeature(rawValue: 0x400)
        static let replica = RoCompatFeature(rawValue: 0x800)
        static let readonly = RoCompatFeature(rawValue: 0x1000)
        static let project = RoCompatFeature(rawValue: 0x2000)
    }

    struct BlockGroupFlag {
        let rawValue: UInt16

        static let inodeUninit = BlockGroupFlag(rawValue: 0x1)
        static let blockUninit = BlockGroupFlag(rawValue: 0x2)
        static let inodeZeroed = BlockGroupFlag(rawValue: 0x4)
    }

    struct GroupDescriptor {
        let blockBitmapLow: UInt32
        let inodeBitmapLow: UInt32
        let inodeTableLow: UInt32
        let freeBlocksCountLow: UInt16
        let freeInodesCountLow: UInt16
        let usedDirsCountLow: UInt16
        let flags: UInt16
        let excludeBitmapLow: UInt32
        let blockBitmapCsumLow: UInt16
        let inodeBitmapCsumLow: UInt16
        let itableUnusedLow: UInt16
        let checksum: UInt16
    }

    struct GroupDescriptor64 {
        let groupDescriptor: GroupDescriptor
        let blockBitmapHigh: UInt32
        let inodeBitmapHigh: UInt32
        let inodeTableHigh: UInt32
        let freeBlocksCountHigh: UInt16
        let freeInodesCountHigh: UInt16
        let usedDirsCountHigh: UInt16
        let itableUnusedHigh: UInt16
        let excludeBitmapHigh: UInt32
        let blockBitmapCsumHigh: UInt16
        let inodeBitmapCsumHigh: UInt16
        let reserved: UInt32
    }

    public struct FileModeFlag: Sendable {
        let rawValue: UInt16

        public static let S_IXOTH = FileModeFlag(rawValue: 0x1)
        public static let S_IWOTH = FileModeFlag(rawValue: 0x2)
        public static let S_IROTH = FileModeFlag(rawValue: 0x4)
        public static let S_IXGRP = FileModeFlag(rawValue: 0x8)
        public static let S_IWGRP = FileModeFlag(rawValue: 0x10)
        public static let S_IRGRP = FileModeFlag(rawValue: 0x20)
        public static let S_IXUSR = FileModeFlag(rawValue: 0x40)
        public static let S_IWUSR = FileModeFlag(rawValue: 0x80)
        public static let S_IRUSR = FileModeFlag(rawValue: 0x100)
        public static let S_ISVTX = FileModeFlag(rawValue: 0x200)
        public static let S_ISGID = FileModeFlag(rawValue: 0x400)
        public static let S_ISUID = FileModeFlag(rawValue: 0x800)
        public static let S_IFIFO = FileModeFlag(rawValue: 0x1000)
        public static let S_IFCHR = FileModeFlag(rawValue: 0x2000)
        public static let S_IFDIR = FileModeFlag(rawValue: 0x4000)
        public static let S_IFBLK = FileModeFlag(rawValue: 0x6000)
        public static let S_IFREG = FileModeFlag(rawValue: 0x8000)
        public static let S_IFLNK = FileModeFlag(rawValue: 0xA000)
        public static let S_IFSOCK = FileModeFlag(rawValue: 0xC000)

        public static let TypeMask = FileModeFlag(rawValue: 0xF000)
    }

    public typealias InodeNumber = UInt32

    public struct Inode {
        var mode: UInt16 = 0
        var uid: UInt16 = 0
        var sizeLow: UInt32 = 0
        var atime: UInt32 = 0
        var ctime: UInt32 = 0
        var mtime: UInt32 = 0
        var dtime: UInt32 = 0
        var gid: UInt16 = 0
        var linksCount: UInt16 = 0
        var blocksLow: UInt32 = 0
        var flags: UInt32 = 0
        var version: UInt32 = 0
        var block:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            )
        var generation: UInt32 = 0
        var xattrBlockLow: UInt32 = 0
        var sizeHigh: UInt32 = 0
        var obsoleteFragmentAddr: UInt32 = 0
        var blocksHigh: UInt16 = 0
        var xattrBlockHigh: UInt16 = 0
        var uidHigh: UInt16 = 0
        var gidHigh: UInt16 = 0
        var checksumLow: UInt16 = 0
        var reserved: UInt16 = 0
        var extraIsize: UInt16 = 0
        var checksumHigh: UInt16 = 0
        var ctimeExtra: UInt32 = 0
        var mtimeExtra: UInt32 = 0
        var atimeExtra: UInt32 = 0
        var crtime: UInt32 = 0
        var crtimeExtra: UInt32 = 0
        var versionHigh: UInt32 = 0
        var projid: UInt32 = 0  // Size until this point is 160 bytes
        var inlineXattrs:
            (  // 96 bytes for extended attributes
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0
            )

        public static func Mode(_ mode: FileModeFlag, _ perm: UInt16) -> UInt16 {
            mode.rawValue | perm
        }
    }

    struct InodeFlag {
        let rawValue: UInt32

        static let secRm = InodeFlag(rawValue: 0x1)
        static let unRm = InodeFlag(rawValue: 0x2)
        static let compressed = InodeFlag(rawValue: 0x4)
        static let sync = InodeFlag(rawValue: 0x8)
        static let immutable = InodeFlag(rawValue: 0x10)
        static let append = InodeFlag(rawValue: 0x20)
        static let noDump = InodeFlag(rawValue: 0x40)
        static let noAtime = InodeFlag(rawValue: 0x80)
        static let dirtyCompressed = InodeFlag(rawValue: 0x100)
        static let compressedClusters = InodeFlag(rawValue: 0x200)
        static let noCompress = InodeFlag(rawValue: 0x400)
        static let encrypted = InodeFlag(rawValue: 0x800)
        static let hashedIndex = InodeFlag(rawValue: 0x1000)
        static let magic = InodeFlag(rawValue: 0x2000)
        static let journalData = InodeFlag(rawValue: 0x4000)
        static let noTail = InodeFlag(rawValue: 0x8000)
        static let dirSync = InodeFlag(rawValue: 0x10000)
        static let topDir = InodeFlag(rawValue: 0x20000)
        static let hugeFile = InodeFlag(rawValue: 0x40000)
        static let extents = InodeFlag(rawValue: 0x80000)
        static let eaInode = InodeFlag(rawValue: 0x200000)
        static let eofBlocks = InodeFlag(rawValue: 0x400000)
        static let snapfile = InodeFlag(rawValue: 0x0100_0000)
        static let snapfileDeleted = InodeFlag(rawValue: 0x0400_0000)
        static let snapfileShrunk = InodeFlag(rawValue: 0x0800_0000)
        static let inlineData = InodeFlag(rawValue: 0x1000_0000)
        static let projectIDInherit = InodeFlag(rawValue: 0x2000_0000)
        static let reserved = InodeFlag(rawValue: 0x8000_0000)
    }

    struct ExtentHeader {
        let magic: UInt16
        let entries: UInt16
        let max: UInt16
        let depth: UInt16
        let generation: UInt32
    }

    struct ExtentIndex {
        let block: UInt32
        let leafLow: UInt32
        let leafHigh: UInt16
        let unused: UInt16
    }

    struct ExtentLeaf {
        let block: UInt32
        let length: UInt16
        let startHigh: UInt16
        let startLow: UInt32
    }

    struct ExtentTail {
        let checksum: UInt32
    }

    struct ExtentIndexNode {
        var header: ExtentHeader
        var indices: [ExtentIndex]
    }

    struct ExtentLeafNode {
        var header: ExtentHeader
        var leaves: [ExtentLeaf]
    }

    struct DirectoryEntry {
        let inode: InodeNumber
        let recordLength: UInt16
        let nameLength: UInt8
        let fileType: UInt8
        // let name: [UInt8]
    }

    enum FileType: UInt8 {
        case unknown = 0x0
        case regular = 0x1
        case directory = 0x2
        case character = 0x3
        case block = 0x4
        case fifo = 0x5
        case socket = 0x6
        case symbolicLink = 0x7
    }

    struct DirectoryEntryTail {
        let reservedZero1: UInt32
        let recordLength: UInt16
        let reservedZero2: UInt8
        let fileType: UInt8
        let checksum: UInt32
    }

    struct DirectoryTreeRoot {
        let dot: DirectoryEntry
        let dotName: [UInt8]
        let dotDot: DirectoryEntry
        let dotDotName: [UInt8]
        let reservedZero: UInt32
        let hashVersion: UInt8
        let infoLength: UInt8
        let indirectLevels: UInt8
        let unusedFlags: UInt8
        let limit: UInt16
        let count: UInt16
        let block: UInt32
        // let entries: [DirectoryTreeEntry]
    }

    struct DirectoryTreeNode {
        let fakeInode: UInt32
        let fakeRecordLength: UInt16
        let nameLength: UInt8
        let fileType: UInt8
        let limit: UInt16
        let count: UInt16
        let block: UInt32
        // let entries: [DirectoryTreeEntry]
    }

    struct DirectoryTreeEntry {
        let hash: UInt32
        let block: UInt32
    }

    struct DirectoryTreeTail {
        let reserved: UInt32
        let checksum: UInt32
    }

    struct XAttrEntry {
        let nameLength: UInt8
        let nameIndex: UInt8
        let valueOffset: UInt16
        let valueInum: UInt32
        let valueSize: UInt32
        let hash: UInt32
    }

    struct XAttrHeader {
        let magic: UInt32
        let referenceCount: UInt32
        let blocks: UInt32
        let hash: UInt32
        let checksum: UInt32
        let reserved: [UInt32]
    }

}

extension EXT4.Inode {
    public static func Root() -> EXT4.Inode {
        var inode = Self()  // inode
        inode.mode = Self.Mode(.S_IFDIR, 0o755)
        inode.linksCount = 2
        inode.uid = 0
        inode.gid = 0
        // time
        let now = Date().fs()
        let now_lo: UInt32 = now.lo
        let now_hi: UInt32 = now.hi
        inode.atime = now_lo
        inode.atimeExtra = now_hi
        inode.ctime = now_lo
        inode.ctimeExtra = now_hi
        inode.mtime = now_lo
        inode.mtimeExtra = now_hi
        inode.crtime = now_lo
        inode.crtimeExtra = now_hi
        inode.flags = EXT4.InodeFlag.hugeFile.rawValue
        inode.extraIsize = UInt16(EXT4.ExtraIsize)
        return inode
    }

}
