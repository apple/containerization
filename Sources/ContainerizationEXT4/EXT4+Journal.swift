//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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

// JBD2 on-disk format reference:
// https://www.kernel.org/doc/html/latest/filesystems/ext4/journal.html

extension EXT4.Formatter {
    /// Entry point called from close() when journaling is enabled.
    func initializeJournal(
        config: EXT4.JournalConfig,
        filesystemUUID: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )
    ) throws {
        let journalBlocks = calculateJournalSize(requestedSize: config.size, totalBlocks: blockCount)
        // Align to block boundary before recording start.
        if self.pos % self.blockSize != 0 {
            try self.seek(block: self.currentBlock + 1)
        }
        let journalStartBlock = self.currentBlock
        try writeJournalSuperblock(journalBlocks: journalBlocks, filesystemUUID: filesystemUUID)
        try zeroJournalBlocks(count: journalBlocks - 1)
        setupJournalInode(startBlock: journalStartBlock, blockCount: journalBlocks)
    }

    // MARK: - Private helpers

    private func calculateJournalSize(requestedSize: UInt64?, totalBlocks: UInt32) -> UInt32 {
        if let size = requestedSize {
            // Clamp to UInt32.max: the kernel caps internal journals at 2^32 blocks
            // (per §3.6.4 s_maxlen), and a caller-supplied size large enough to exceed
            // that would otherwise trap on the narrowing conversion.
            let blocks = size / UInt64(self.blockSize)
            return UInt32(min(blocks, UInt64(UInt32.max)))
        }
        let fsBytes = UInt64(totalBlocks) * UInt64(self.blockSize)
        let rawBytes = fsBytes / 256
        let minBytes: UInt64 = 4.mib()
        let maxBytes: UInt64 = 128.mib()
        let clampedBytes = min(max(rawBytes, minBytes), maxBytes)
        // Safe: clampedBytes ≤ 128 MiB, so the quotient is at most 131,072 — well within UInt32.
        return UInt32(clampedBytes / UInt64(self.blockSize))
    }

    private func writeJournalSuperblock(
        journalBlocks: UInt32,
        filesystemUUID: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )
    ) throws {
        // Safe: blockSize is UInt32; widening to Int (64-bit on all supported platforms) never truncates.
        var buf = [UInt8](repeating: 0, count: Int(self.blockSize))

        func writeU32(_ value: UInt32, at offset: Int) {
            buf[offset] = UInt8((value >> 24) & 0xFF)
            buf[offset + 1] = UInt8((value >> 16) & 0xFF)
            buf[offset + 2] = UInt8((value >> 8) & 0xFF)
            buf[offset + 3] = UInt8(value & 0xFF)
        }

        // JBD2 block header (§3.6.3): https://www.kernel.org/doc/html/latest/filesystems/ext4/journal.html#block-header
        writeU32(EXT4.JournalMagic, at: 0x00)  // h_magic
        writeU32(4, at: 0x04)  // h_blocktype = superblock v2
        writeU32(1, at: 0x08)  // h_sequence

        // JBD2 superblock body (§3.6.4): https://www.kernel.org/doc/html/latest/filesystems/ext4/journal.html#super-block
        writeU32(self.blockSize, at: 0x0C)  // s_blocksize
        writeU32(journalBlocks, at: 0x10)  // s_maxlen
        writeU32(1, at: 0x14)  // s_first (first usable block)
        writeU32(1, at: 0x18)  // s_sequence
        // 0x1C s_start: left zero — kernel treats zero as "journal empty, begin at s_first"
        // 0x20 s_errno: left zero — no prior abort error
        // 0x24 s_feature_compat: left zero — no optional features (e.g. data-block checksums)
        // 0x28 s_feature_incompat: left zero — non-zero unrecognised flags would cause mount refusal
        // 0x2C s_feature_ro_compat: left zero — no flags defined by the spec

        // s_uuid at 0x30 (16 bytes)
        let uuidBytes = [
            filesystemUUID.0, filesystemUUID.1, filesystemUUID.2, filesystemUUID.3,
            filesystemUUID.4, filesystemUUID.5, filesystemUUID.6, filesystemUUID.7,
            filesystemUUID.8, filesystemUUID.9, filesystemUUID.10, filesystemUUID.11,
            filesystemUUID.12, filesystemUUID.13, filesystemUUID.14, filesystemUUID.15,
        ]
        buf[0x30..<0x40] = uuidBytes[...]

        writeU32(1, at: 0x40)  // s_nr_users

        let maxTrans = min(journalBlocks / 4, 32768)
        writeU32(maxTrans, at: 0x48)  // s_max_transaction
        writeU32(maxTrans, at: 0x4C)  // s_max_trans_data

        // s_users[0] at 0x100 (first entry of 768-byte users array)
        buf[0x100..<0x110] = uuidBytes[...]

        try self.handle.write(contentsOf: buf)
    }

    private func zeroJournalBlocks(count: UInt32) throws {
        guard count > 0 else { return }
        let chunkSize = 1.mib()
        // Safe: both operands are UInt32, so their product peaks at ~17 TiB, which fits
        // in Int64 (the width of Int on all 64-bit Apple platforms).
        let totalBytes = Int(count) * Int(self.blockSize)
        let zeroBuf = [UInt8](repeating: 0, count: min(Int(chunkSize), totalBytes))
        var remaining = totalBytes
        while remaining > 0 {
            let toWrite = min(zeroBuf.count, remaining)
            try self.handle.write(contentsOf: zeroBuf[0..<toWrite])
            remaining -= toWrite
        }
    }

    private func setupJournalInode(startBlock: UInt32, blockCount: UInt32) {
        var journalInode = EXT4.Inode()
        journalInode.mode = EXT4.Inode.Mode(.S_IFREG, 0o600)
        journalInode.uid = 0
        journalInode.gid = 0
        let size = UInt64(blockCount) * UInt64(self.blockSize)
        journalInode.sizeLow = size.lo
        journalInode.sizeHigh = size.hi
        let now = Date().fs()
        journalInode.atime = now.lo
        journalInode.atimeExtra = now.hi
        journalInode.ctime = now.lo
        journalInode.ctimeExtra = now.hi
        journalInode.mtime = now.lo
        journalInode.mtimeExtra = now.hi
        journalInode.crtime = now.lo
        journalInode.crtimeExtra = now.hi
        journalInode.linksCount = 1
        journalInode.extraIsize = UInt16(EXT4.ExtraIsize)
        journalInode.flags = EXT4.InodeFlag.extents.rawValue

        // Journal is one contiguous allocation → numExtents = 1 → extent tree fits inline
        // in the inode, so writeExtents needs no extra disk I/O for extent index blocks.
        // Safe: the journal is placed inside the filesystem, whose total block count is
        // also a UInt32, so startBlock + blockCount cannot exceed UInt32.max.
        journalInode = (try? self.writeExtents(journalInode, (startBlock, startBlock + blockCount))) ?? journalInode

        self.inodes[Int(EXT4.JournalInode) - 1].initialize(to: journalInode)
    }

    func journalInodeBlockBackup() -> (
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32
    ) {
        let ji = self.inodes[Int(EXT4.JournalInode) - 1].pointee
        // Extract the 15 UInt32 words from the inode's 60-byte extent-tree field,
        // then append sizeLow and sizeHigh as words 15 and 16.
        var words = [UInt32](repeating: 0, count: 17)
        withUnsafeBytes(of: ji.block) { bytes in
            for i in 0..<15 {
                words[i] = bytes.load(fromByteOffset: i * 4, as: UInt32.self)
            }
        }
        words[15] = ji.sizeLow
        words[16] = ji.sizeHigh
        return (
            words[0], words[1], words[2], words[3],
            words[4], words[5], words[6], words[7],
            words[8], words[9], words[10], words[11],
            words[12], words[13], words[14], words[15],
            words[16]
        )
    }
}
