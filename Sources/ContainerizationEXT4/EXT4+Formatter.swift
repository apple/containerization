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

//  swiftlint: disable discouraged_direct_init shorthand_operator syntactic_sugar

import ContainerizationArchive
import ContainerizationOS
import Foundation
import SystemPackage

extension EXT4 {
    /// The `EXT4.Formatter` class provides methods to format a block device with the ext4 filesystem.
    /// It allows customization of block size and maximum disk size.
    public class Formatter {
        let blockSize: UInt32
        private var size: UInt64
        private let groupDescriptorSize: UInt32 = 32

        private var blocksPerGroup: UInt32 {
            blockSize * 8
        }

        private var maxInodesPerGroup: UInt32 {
            blockSize * 8  // limited by inode bitmap
        }

        private var groupsPerDescriptorBlock: UInt32 {
            blockSize / groupDescriptorSize
        }

        private var blockCount: UInt32 {
            ((size - 1) / blockSize) + 1
        }

        private var groupCount: UInt32 {
            (blockCount - 1) / blocksPerGroup + 1
        }

        private var groupDescriptorBlocks: UInt32 {
            ((groupCount - 1) / groupsPerDescriptorBlock + 1) * 32
        }

        /// Initializes an ext4 filesystem formatter.
        ///
        /// This constructor creates an instance of the ext4 formatter designed to format a block device
        /// with the ext4 filesystem. The formatter takes the path to the destination block device and
        /// the desired block size of the filesystem as parameters.
        ///
        /// - Parameters:
        ///   - devicePath: The path to the block device where the ext4 filesystem will be created.
        ///   - blockSize: The block size of the ext4 filesystem, specified in bytes. Common values are
        ///                4096 (4KB) or 1024 (1KB). Default is 4096 (4KB)
        ///   - minDiskSize: The minimum disk size required for the formatted filesystem.
        ///
        /// - Note: This ext4 formatter is designed for creating block devices out of container images and does not support all the
        ///         features and options available in the full ext4 filesystem implementation. It focuses
        ///         on the core functionality required for formatting a block device with ext4.
        ///
        /// - Important: Ensure that the destination block device is accessible and has sufficient permissions
        ///              for formatting. The formatting process will erase all existing data on the device.
        public init(_ devicePath: FilePath, blockSize: UInt32 = 4096, minDiskSize: UInt64 = 256.kib()) throws {
            /// The constructor performs the following steps:
            ///
            /// 1. Creates the first 10 inodes:
            ///    - Inode 2 is reserved for the root directory ('/').
            ///    - Inodes 1 and 3-10 are reserved for other special purposes.
            ///
            /// 2. Marks inode 11 as the first inode available for consumption by files, directories, sockets,
            ///    FIFOs, etc.
            ///
            /// 3. Initializes a directory tree with the root directory pointing to inode 2.
            ///
            /// 4. Moves the file descriptor to the start of the block where file metadata and data can be
            ///    written, which is located past the filesystem superblocks and group descriptor blocks.
            ///
            /// 5. Creates a "/lost+found" directory to satisfy the requirements of e2fsck (ext2/3/4 filesystem
            ///    checker).

            if !FileManager.default.fileExists(atPath: devicePath.description) {
                FileManager.default.createFile(atPath: devicePath.description, contents: nil)
            }
            guard let fileHandle = FileHandle(forWritingTo: devicePath) else {
                throw Error.notFound(devicePath)
            }
            self.handle = fileHandle
            self.blockSize = blockSize
            self.size = minDiskSize
            // make this a 0 byte file
            guard ftruncate(self.handle.fileDescriptor, 0) == 0 else {
                throw Error.cannotTruncateFile(devicePath)
            }
            // make it a sparse file
            guard lseek(self.handle.fileDescriptor, off_t(self.size - 1), 0) == self.size - 1 else {
                throw Error.cannotCreateSparseFile(devicePath)
            }
            let zero: [UInt8] = [0]
            try self.handle.write(contentsOf: zero)
            // step #1
            self.inodes = [
                Ptr<Inode>.allocate(capacity: 1),  // defective block inode
                {
                    let root = Inode.Root()
                    let rootPtr = Ptr<Inode>.allocate(capacity: 1)
                    rootPtr.initialize(to: root)
                    return rootPtr
                }(),
            ]
            // reserved inodes
            for _ in 2..<EXT4.FirstInode - 1 {
                inodes.append(Ptr<Inode>.allocate(capacity: 1))
            }
            // step #2
            self.tree = FileTree(EXT4.RootInode, "/")
            // skip past the superblock and block descriptor table
            try self.seek(block: self.groupDescriptorBlocks + 1)
            // lost+found directory is required for e2fsck to pass
            try self.create(path: FilePath("/lost+found"), mode: Inode.Mode(.S_IFDIR, 0o700))
        }

        // Creates a hard link at the path specified by `link` that points to the same file or directory as the path specified by `target`.
        //
        // A hard link is a directory entry that points to the same inode as another directory entry. It allows multiple paths to refer to the same file on the file system.
        //
        // - `link`: The path at which to create the new hard link.
        // - `target`: The path of the existing file or directory to which the hard link should point.
        //
        // Throws an error if `target` path does not exist, or `target` is a directory.
        public func link(
            link: FilePath,
            target: FilePath
        ) throws {
            // ensure that target exists
            guard let targetPtr = self.tree.lookup(path: target) else {
                throw Error.notFound(target)
            }
            let targetNode = targetPtr.pointee
            let targetInodePtr = self.inodes[Int(targetNode.inode) - 1]
            var targetInode = targetInodePtr.pointee
            // ensure that target is not a directory since hardlinks cannot be
            // created to directories
            if targetInode.mode.isDir() {
                throw Error.cannotCreateHardlinksToDirTarget(link)
            }
            targetInode.linksCount += 1
            targetInodePtr.initialize(to: targetInode)
            let parentPath: FilePath = link.dir
            if self.tree.lookup(path: link) != nil {
                try self.unlink(path: link)
            }
            guard let parentTreeNodePtr = self.tree.lookup(path: parentPath) else {
                throw Error.notFound(parentPath)
            }
            let parentTreeNode = parentTreeNodePtr.pointee
            let parentInodePtr = self.inodes[Int(parentTreeNode.inode) - 1]
            let parentInode = parentInodePtr.pointee
            guard parentInode.linksCount < EXT4.MaxLinks else {
                throw Error.maximumLinksExceeded(parentPath)
            }
            let linkTreeNodePtr = Ptr<FileTree.FileTreeNode>.allocate(capacity: 1)
            let linkTreeNode = FileTree.FileTreeNode(
                inode: InodeNumber(2),  // this field is ignored, using 2 so array operations dont panic
                name: link.base,
                parent: parentTreeNodePtr,
                children: [],
                blocks: nil,
                link: targetNode.inode
            )
            linkTreeNodePtr.initialize(to: linkTreeNode)
            parentTreeNode.children.append(linkTreeNodePtr)
            parentTreeNodePtr.initialize(to: parentTreeNode)
        }

        // Deletes the file or directory at the specified path from the filesystem.
        //
        // It performs the following actions
        // - set link count of the file's inode to 0
        // - recursively set link count to 0 for its children
        // - free the inode
        // - free data blocks
        // - remove directory entry
        //
        // - `path`: The `FilePath` specifying the path of the file or directory to delete.
        public func unlink(path: FilePath, directoryWhiteout: Bool = false) throws {
            guard let pathPtr = self.tree.lookup(path: path) else {
                // We are being asked to unlink something that does not exist. Ignore
                return
            }
            let pathNode = pathPtr.pointee
            let inodeNumber = Int(pathNode.inode) - 1
            let pathInodePtr = self.inodes[inodeNumber]
            var pathInode = pathInodePtr.pointee

            if directoryWhiteout && !pathInode.mode.isDir() {
                throw Error.notDirectory(path)
            }

            for childPtr in pathNode.children {
                try self.unlink(path: path.join(childPtr.pointee.name))
            }

            guard !directoryWhiteout else {
                return
            }

            if let parentNodePtr = self.tree.lookup(path: path.dir) {
                let parentNode = parentNodePtr.pointee
                let parentInodePtr = self.inodes[Int(parentNode.inode) - 1]
                var parentInode = parentInodePtr.pointee
                if pathInode.mode.isDir() {
                    if parentInode.linksCount > 2 {
                        parentInode.linksCount -= 1
                    }
                }
                parentInodePtr.initialize(to: parentInode)
                parentNode.children.removeAll { childPtr in
                    childPtr.pointee.name == path.base
                }
                parentNodePtr.initialize(to: parentNode)
            }

            if let hardlink = pathNode.link {
                // the file we are deleting is a hardlink, decrement the link count
                let linkedInodePtr = self.inodes[Int(hardlink - 1)]
                var linkedInode = linkedInodePtr.pointee
                if linkedInode.linksCount > 2 {
                    linkedInode.linksCount -= 1
                    linkedInodePtr.initialize(to: linkedInode)
                }
            }

            guard inodeNumber > FirstInode else {
                // Free the inodes and the blocks related to the inode only if its valid
                return
            }
            if let blocks = pathNode.blocks {
                if !(blocks.start == blocks.end) {
                    self.deletedBlocks.append((start: blocks.start, end: blocks.end))
                }
            }
            for block in pathNode.additionalBlocks ?? [] {
                self.deletedBlocks.append((start: block.start, end: block.end))
            }
            let now = Date().fs()
            pathInode = Inode()
            pathInode.dtime = now.lo
            pathInodePtr.initialize(to: pathInode)
        }

        //  Creates a file, directory, or symlink at the specified path, recursively creating parent directories if they don't already exist.
        //
        //  - Parameters:
        //    - path: The FilePath representing the path where the file, directory, or symlink should be created.
        //    - link: An optional FilePath representing the target path for a symlink. If `nil`, a regular file or directory will be created. Preceding '/' should be omitted
        //    - mode: The permissions to set for the created file, directory, or symlink.
        //    - buf: A `ReadableStream` object providing the contents for the created file. Ignored when creating directories or symlinks.
        //
        //  - Note:
        //    - This function recursively creates parent directories if they don't already exist. The `uid` and `gid` of the created parent directories are set to the values of their parent's `uid` and `gid`.
        //    - It is expected that the user sets the permissions explicitly later
        //    - This function only supports creating files, directories, and symlinks. Attempting to create other types of file system objects will result in an error.
        //    - In case of symlinks, the preceding '/' should be omitted
        //
        //  - Example usage:
        //    ```swift
        //     let formatter = EXT4.Formatter(devicePath: "ext4.img")
        //     // create a directory
        //     try formatter.create(path: FilePath("/dir"),
        //         mode: EXT4.Inode.Mode(.S_IFDIR, 0o700))
        //
        //     // create a file
        //     let inputStream = InputStream(data: "data".data(using: .utf8)!)
        //     inputStream.open()
        //     try formatter.create(path: FilePath("/dir/file"),
        //         mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: inputStream)
        //     inputStream.close()
        //
        //     // create a symlink
        //     try formatter.create(path: FilePath("/symlink"), link: "/dir/file",
        //         mode: EXT4.Inode.Mode(.S_IFLNK, 0o700))
        //    ```
        public func create(
            path: FilePath,
            link: FilePath? = nil,  // to create symbolic links
            mode: UInt16,
            ts: FileTimestamps = FileTimestamps(),
            buf: (any ReadableStream)? = nil,
            uid: UInt32? = nil,
            gid: UInt32? = nil,
            xattrs: [String: Data]? = nil,
            recursion: Bool = false,
            fileBuffer: UnsafeMutableBufferPointer<UInt8>? = nil
        ) throws {
            if let nodePtr = self.tree.lookup(path: path) {
                let node = nodePtr.pointee
                let inodePtr = self.inodes[Int(node.inode) - 1]
                let inode = inodePtr.pointee
                // Allowed replace
                // -----------------------------
                //
                // Original Type    File    Directory    Symlink
                // ----------------------------------------------
                // File           |  ✔    |     ✘      |     ✔
                // Directory      |  ✘    |     ✔      |     ✔
                // Symlink        |  ✔    |     ✘      |     ✔
                if mode.isDir() {
                    if !inode.mode.isDir() {
                        guard inode.mode.isLink() else {
                            throw Error.notDirectory(path)
                        }
                    }
                    // mkdir -p
                    if path.base == node.name {
                        guard !recursion else {
                            return
                        }
                        // create a new tree node to replace this one
                        var inode = inode
                        inode.mode = mode
                        if let uid {
                            inode.uid = uid.lo
                            inode.uidHigh = uid.hi
                        }
                        if let gid {
                            inode.gid = gid.lo
                            inode.gidHigh = gid.hi
                        }
                        inodePtr.initialize(to: inode)
                        return
                    }
                } else if let _ = node.link {  // ok to overwrite links
                    try self.unlink(path: path)
                } else {  // file can only be overwritten by another file
                    if inode.mode.isDir() {
                        guard mode.isLink() else {  // unless it is a link, then it can be replaced by a dir
                            throw Error.notFile(path)
                        }
                    }
                    try self.unlink(path: path)
                }
            }
            // create all predecessors recursively
            let parentPath: FilePath = path.dir
            try self.create(path: parentPath, mode: Inode.Mode(.S_IFDIR, 0o755), recursion: true)
            guard let parentTreeNodePtr = self.tree.lookup(path: parentPath) else {
                throw Error.notFound(parentPath)
            }
            let parentTreeNode = parentTreeNodePtr.pointee
            let parentInodePtr = self.inodes[Int(parentTreeNode.inode) - 1]
            var parentInode = parentInodePtr.pointee
            guard parentInode.linksCount < EXT4.MaxLinks else {
                throw Error.maximumLinksExceeded(parentPath)
            }

            let childInodePtr = Ptr<Inode>.allocate(capacity: 1)
            var childInode = Inode()
            var startBlock: UInt32 = 0
            var endBlock: UInt32 = 0
            defer {  // update metadata
                childInodePtr.initialize(to: childInode)
                parentInodePtr.initialize(to: parentInode)
                self.inodes.append(childInodePtr)
                let childTreeNodePtr = Ptr<FileTree.FileTreeNode>.allocate(capacity: 1)
                let childTreeNode = FileTree.FileTreeNode(
                    inode: InodeNumber(self.inodes.count),
                    name: path.base,
                    parent: parentTreeNodePtr,
                    children: [],
                    blocks: (startBlock, endBlock)
                )
                childTreeNodePtr.initialize(to: childTreeNode)
                parentTreeNode.children.append(childTreeNodePtr)
                parentTreeNodePtr.initialize(to: parentTreeNode)
            }
            childInode.mode = mode
            // uid,gid
            if let uid {
                childInode.uid = UInt16(uid & 0xffff)
                childInode.uidHigh = UInt16((uid >> 16) & 0xffff)
            } else {
                childInode.uid = parentInode.uid
                childInode.uidHigh = parentInode.uidHigh
            }
            if let gid {
                childInode.gid = UInt16(gid & 0xffff)
                childInode.gidHigh = UInt16((gid >> 16) & 0xffff)
            } else {
                childInode.gid = parentInode.gid
                childInode.gidHigh = parentInode.gidHigh
            }
            if let xattrs, !xattrs.isEmpty {
                var state = FileXattrsState(
                    inode: UInt32(self.inodes.count), inodeXattrCapacity: EXT4.InodeExtraSize, blockCapacity: blockSize)
                try state.add(ExtendedAttribute(name: "system.data", value: []))
                for (s, d) in xattrs {
                    let attribute = ExtendedAttribute(name: s, value: [UInt8](d))
                    try state.add(attribute)
                }
                if !state.inlineAttributes.isEmpty {
                    var buffer: [UInt8] = .init(repeating: 0, count: Int(EXT4.InodeExtraSize))
                    try state.writeInlineAttributes(buffer: &buffer)
                    childInode.inlineXattrs = (
                        buffer[0], buffer[1], buffer[2], buffer[3], buffer[4], buffer[5], buffer[6], buffer[7],
                        buffer[8],
                        buffer[9],
                        buffer[10], buffer[11], buffer[12], buffer[13], buffer[14], buffer[15], buffer[16], buffer[17],
                        buffer[18],
                        buffer[19],
                        buffer[20], buffer[21], buffer[22], buffer[23], buffer[24], buffer[25], buffer[26], buffer[27],
                        buffer[28],
                        buffer[29],
                        buffer[30], buffer[31], buffer[32], buffer[33], buffer[34], buffer[35], buffer[36], buffer[37],
                        buffer[38],
                        buffer[39],
                        buffer[40], buffer[41], buffer[42], buffer[43], buffer[44], buffer[45], buffer[46], buffer[47],
                        buffer[48],
                        buffer[49],
                        buffer[50], buffer[51], buffer[52], buffer[53], buffer[54], buffer[55], buffer[56], buffer[57],
                        buffer[58],
                        buffer[59],
                        buffer[60], buffer[61], buffer[62], buffer[63], buffer[64], buffer[65], buffer[66], buffer[67],
                        buffer[68],
                        buffer[69],
                        buffer[70], buffer[71], buffer[72], buffer[73], buffer[74], buffer[75], buffer[76], buffer[77],
                        buffer[78],
                        buffer[79],
                        buffer[80], buffer[81], buffer[82], buffer[83], buffer[84], buffer[85], buffer[86], buffer[87],
                        buffer[88],
                        buffer[89],
                        buffer[90], buffer[91], buffer[92], buffer[93], buffer[94], buffer[95]
                    )
                }
                if !state.blockAttributes.isEmpty {
                    var buffer: [UInt8] = .init(repeating: 0, count: Int(blockSize))
                    try state.writeBlockAttributes(buffer: &buffer)
                    if self.pos % self.blockSize != 0 {
                        try self.seek(block: self.currentBlock + 1)
                    }
                    childInode.xattrBlockLow = self.currentBlock
                    try self.handle.write(contentsOf: buffer)
                    childInode.blocksLow += 1
                }
            }

            childInode.atime = ts.accessLo
            childInode.atimeExtra = ts.accessHi
            // ctime is the last time the inode was changed which is now
            childInode.ctime = ts.nowLo
            childInode.ctimeExtra = ts.nowHi
            childInode.mtime = ts.modificationLo
            childInode.mtimeExtra = ts.modificationHi
            childInode.crtime = ts.creationLo
            childInode.crtimeExtra = ts.creationHi
            childInode.linksCount = 1
            childInode.extraIsize = UInt16(EXT4.ExtraIsize)
            // flags
            childInode.flags = InodeFlag.hugeFile.rawValue
            // size check
            var size: UInt64 = 0
            // align with block boundary
            if self.pos % self.blockSize != 0 {
                try self.seek(block: self.currentBlock + 1)
            }
            // dir
            if childInode.mode.isDir() {
                childInode.linksCount += 1
                parentInode.linksCount += 1
                // to pass e2fsck, the convention is to sort children
                // before committing to disk. Therefore, we are deferring
                // writing dentries until commit() is called
                return
            }
            // symbolic link
            if let link {
                startBlock = self.currentBlock
                let linkPath = link.bytes
                if linkPath.count < 60 {
                    size += UInt64(linkPath.count)
                    var blockData: [UInt8] = .init(repeating: 0, count: 60)
                    for i in 0..<linkPath.count {
                        blockData[i] = linkPath[i]
                    }
                    childInode.block = (
                        blockData[0], blockData[1], blockData[2], blockData[3], blockData[4], blockData[5],
                        blockData[6],
                        blockData[7], blockData[8], blockData[9],
                        blockData[10], blockData[11], blockData[12], blockData[13], blockData[14], blockData[15],
                        blockData[16],
                        blockData[17], blockData[18], blockData[19],
                        blockData[20], blockData[21], blockData[22], blockData[23], blockData[24], blockData[25],
                        blockData[26],
                        blockData[27], blockData[28], blockData[29],
                        blockData[30], blockData[31], blockData[32], blockData[33], blockData[34], blockData[35],
                        blockData[36],
                        blockData[37], blockData[38], blockData[39],
                        blockData[40], blockData[41], blockData[42], blockData[43], blockData[44], blockData[45],
                        blockData[46],
                        blockData[47], blockData[48], blockData[49],
                        blockData[50], blockData[51], blockData[52], blockData[53], blockData[54], blockData[55],
                        blockData[56],
                        blockData[57], blockData[58], blockData[59]
                    )
                } else {
                    try linkPath.withUnsafeBytes { buffer in
                        try withUnsafeLittleEndianBuffer(of: buffer) { b in
                            try self.handle.write(contentsOf: b)
                        }
                        size += UInt64(buffer.count)
                    }
                }
                if self.pos % self.blockSize != 0 {
                    try self.seek(block: self.currentBlock + 1)
                }
                endBlock = self.currentBlock
                childInode.sizeLow = size.lo
                childInode.sizeHigh = size.hi
                childInode.mode |= 0o777
                childInode.flags = 0
                if linkPath.count < 60 {
                    childInode.blocksLow = 0
                } else {
                    childInode = try self.writeExtents(childInode, (startBlock, endBlock))
                    childInode.blocksLow = 8
                }
                return
            }
            // regular file
            if mode.isReg() {
                startBlock = self.currentBlock
                if let buf {  // in case of empty files, this will be nil
                    let tempBuf: UnsafeMutablePointer<UInt8>
                    let bufferSize: Int
                    let shouldDeallocate: Bool
                    if let fileBuffer {
                        tempBuf = fileBuffer.baseAddress!
                        bufferSize = fileBuffer.count
                        shouldDeallocate = false
                    } else {
                        tempBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(self.blockSize))
                        bufferSize = Int(self.blockSize)
                        shouldDeallocate = true
                    }
                    defer {
                        if shouldDeallocate {
                            tempBuf.deallocate()
                        }
                    }
                    while case let block = buf.read(tempBuf, maxLength: bufferSize), block > 0 {
                        size += UInt64(block)
                        if size > EXT4.MaxFileSize {
                            throw Error.fileTooBig(size)
                        }
                        let data = UnsafeRawBufferPointer(start: tempBuf, count: block)
                        try withUnsafeLittleEndianBuffer(of: data) { b in
                            try self.handle.write(contentsOf: b)
                        }
                    }
                }
                if self.pos % self.blockSize != 0 {
                    try self.seek(block: self.currentBlock + 1)
                }
                endBlock = self.currentBlock
                childInode.sizeLow = size.lo
                childInode.sizeHigh = size.hi
                childInode = try self.writeExtents(childInode, (startBlock, endBlock))
                return
            }
            // FIFO, Socket and other types are not handled
            throw Error.unsupportedFiletype
        }

        //  Completes the formatting of an ext4 filesystem after writing the necessary structures.
        //
        //  This function is responsible for finalizing the formatting process of an ext4 filesystem
        //  after the following structures have been written:
        //  - Inode table: Contains information about each file and directory in the filesystem.
        //  - Block bitmap: Tracks the allocation status of each block in the filesystem.
        //  - Inode bitmap: Tracks the allocation status of each inode in the filesystem.
        //  - Directory tree: Represents the hierarchical structure of directories and files.
        //  - Group descriptors: Stores metadata about each block group in the filesystem.
        //  - Superblock: Contains essential information about the filesystem's configuration.
        //
        //  The function performs any necessary final steps to ensure the integrity and consistency
        //  of the ext4 filesystem before it can be mounted and used.
        public func close() throws {
            var breathWiseChildTree: [(parent: Ptr<FileTree.FileTreeNode>?, child: Ptr<FileTree.FileTreeNode>)] = [
                (nil, self.tree.root)
            ]
            while !breathWiseChildTree.isEmpty {
                let (parent, child) = breathWiseChildTree.removeFirst()
                try self.commit(parent, child)  // commit directories iteratively
                if child.pointee.link != nil {
                    continue
                }
                breathWiseChildTree.append(contentsOf: child.pointee.children.map { (child, $0) })
            }
            let blockGroupSize = optimizeBlockGroupLayout(blocks: self.currentBlock, inodes: UInt32(self.inodes.count))
            let inodeTableOffset = try self.commitInodeTable(
                blockGroups: blockGroupSize.blockGroups,
                inodesPerGroup: blockGroupSize.inodesPerGroup
            )
            if self.pos % self.blockSize != 0 {
                try self.seek(block: self.currentBlock + 1)
            }
            // write bitmaps and group descriptors

            let bitmapOffset = self.currentBlock
            let bitmapSize: UInt32 = blockGroupSize.blockGroups * 2  // each group has two bitmaps - for inodes, and for blocks
            let dataSize: UInt32 = bitmapOffset + bitmapSize  // last data block
            var diskSize = dataSize
            var minimumDiskSize = (blockGroupSize.blockGroups - 1) * self.blocksPerGroup + 1
            if blockGroupSize.blockGroups == 1 {
                minimumDiskSize = self.blocksPerGroup  // at least 1 block group
            }
            if diskSize < minimumDiskSize {  // for data + metadata
                diskSize = minimumDiskSize
            }
            if self.size < minimumDiskSize {
                self.size = UInt64(minimumDiskSize) * self.blockSize
            }
            // number of blocks needed for group descriptors
            let groupDescriptorBlockCount: UInt32 = (blockGroupSize.blockGroups - 1) / self.groupsPerDescriptorBlock + 1
            guard groupDescriptorBlockCount <= self.groupDescriptorBlocks else {
                throw Error.insufficientSpaceForGroupDescriptorBlocks
            }

            var totalBlocks: UInt32 = 0
            var totalInodes: UInt32 = 0
            let inodeTableSizePerGroup: UInt32 = blockGroupSize.inodesPerGroup * EXT4.InodeSize / self.blockSize
            var groupDescriptors: [GroupDescriptor] = []

            let minGroups = (((self.pos / UInt64(self.blockSize)) - 1) / UInt64(self.blocksPerGroup)) + 1
            if self.size < minGroups * blocksPerGroup * blockSize {
                self.size = UInt64(minGroups * blocksPerGroup * blockSize)
                let pos = self.pos
                guard lseek(self.handle.fileDescriptor, off_t(self.size - 1), 0) == self.size - 1 else {
                    throw Error.cannotResizeFS(self.size)
                }
                let zero: [UInt8] = [0]
                try self.handle.write(contentsOf: zero)
                try self.handle.seek(toOffset: pos)
            }
            let totalGroups = (((self.size / UInt64(self.blockSize)) - 1) / UInt64(self.blocksPerGroup)) + 1

            // If the provided disk size is not aligned to a blockgroup boundary, it needs to
            // be expanded to the next blockgroup boundary.
            // Example:
            //  Provided disk size: 2 GB + 100MB: 2148 MB
            //  BlockSize: 4096
            //  Blockgroup size: 32768 blocks: 128MB
            //  Number of blocks: 549888
            //  Number of blockgroups = 549888 / 32768 = 16.78125
            //  Aligned disk size = 557056 blocks = 17 blockgroups: 2176 MB
            if self.size < totalGroups * blocksPerGroup * blockSize {
                self.size = UInt64(totalGroups * blocksPerGroup * blockSize)
                let pos = self.pos
                guard lseek(self.handle.fileDescriptor, off_t(self.size - 1), 0) == self.size - 1 else {
                    throw Error.cannotResizeFS(self.size)
                }
                let zero: [UInt8] = [0]
                try self.handle.write(contentsOf: zero)
                try self.handle.seek(toOffset: pos)
            }
            for group in 0..<blockGroupSize.blockGroups {
                // keep track of directories, inodes and block per blockgroup
                var dirs: UInt32 = 0
                var inodes: UInt32 = 0
                var blocks: UInt32 = 0
                // blocks bitmap
                var bitmap: [UInt8] = .init(repeating: 0, count: self.blockSize * 2)  // 1 for blocks, 1 for inodes
                if (group + 1) * UInt32(self.blocksPerGroup) <= dataSize {  // fully allocated group
                    for i in 0..<(self.blockSize) {
                        bitmap[Int(i)] = 0xff  // mark as allocated
                    }
                    blocks = UInt32(self.blocksPerGroup)
                } else if group * UInt32(self.blocksPerGroup) < dataSize {  // partially allocated group
                    for i in 0..<dataSize - group * UInt32(self.blocksPerGroup) {
                        bitmap[Int(i / 8)] |= 1 << (i % 8)
                        blocks += 1
                    }
                }

                if group == 0 {  // unused group descriptor blocks
                    // blocks used by group descriptors

                    let usedGroupDescriptorBlocks = (totalGroups - 1) / self.groupsPerDescriptorBlock + 1
                    for i in 0...usedGroupDescriptorBlocks {
                        bitmap[Int(i / 8)] |= 1 << (i % 8)
                    }
                    for i in usedGroupDescriptorBlocks + 1...self.groupDescriptorBlocks {
                        bitmap[Int(i / 8)] &= ~(1 << (i % 8))
                        blocks -= 1
                    }
                }

                // last blockGroup if not aligned with total size should be marked as allocated
                let remainingBlocks = diskSize % self.blocksPerGroup
                if group == totalGroups - 1 && remainingBlocks != 0 && self.size / self.blockSize < self.blocksPerGroup {
                    for i in remainingBlocks..<self.blocksPerGroup {
                        bitmap[Int(i / 8)] |= 1 << (i % 8)
                    }
                    if remainingBlocks < self.size / self.blockSize {
                        for i in remainingBlocks..<self.size / self.blockSize {
                            bitmap[Int(i / 8)] &= ~(1 << (i % 8))
                        }
                    }
                }

                // mark deleted blocks as free
                for block in self.deletedBlocks {
                    for i in block.start..<block.end where i / self.blocksPerGroup == group {
                        let j = i % self.blocksPerGroup
                        blocks -= UInt32((bitmap[Int(j / 8)] >> (j % 8)) & 1)
                        bitmap[Int(j / 8)] &= ~(1 << (j % 8))
                    }
                }

                // inodes bitmap goes into second bitmap block
                for i in 0..<blockGroupSize.inodesPerGroup {
                    let ino = InodeNumber(1 + group * blockGroupSize.inodesPerGroup + i)
                    if ino > self.inodes.count {
                        continue
                    }
                    let inode = self.inodes[Int(ino) - 1]
                    if ino > 10 && inode.pointee.linksCount == 0 {  // deleted files
                        continue
                    }
                    bitmap[Int(self.blockSize) + Int(i / 8)] |= 1 << (i % 8)
                    inodes += 1
                    if inode.pointee.mode.isDir() {
                        dirs += 1
                    }
                }

                for i in (blockGroupSize.inodesPerGroup / 8)..<self.blockSize {
                    bitmap[Int(self.blockSize) + Int(i)] = 0xff  // mark rest of inodes as occupied
                }

                // write bitmap
                try bitmap.withUnsafeBytes { bitmapBytes in
                    try withUnsafeLittleEndianBuffer(of: bitmapBytes) { b in
                        try self.handle.write(contentsOf: b)
                    }
                }

                var freeBlocks: UInt32 = UInt32(self.blocksPerGroup)
                if freeBlocks < blocks {
                    freeBlocks = 0
                } else if self.size / self.blockSize < self.blocksPerGroup {
                    if blocks < UInt32(self.size / UInt64(self.blockSize)) {
                        freeBlocks = UInt32(self.size / UInt64(self.blockSize)) - blocks
                    } else {
                        freeBlocks = 0
                    }
                } else {
                    freeBlocks = UInt32(self.blocksPerGroup) - blocks
                }

                let blockBitmap = UInt64(bitmapOffset + 2 * group)
                let inodeBitmap = UInt64(bitmapOffset + 2 * group + 1)
                let inodeTable = inodeTableOffset + UInt64(group * inodeTableSizePerGroup)
                let freeBlocksCount = UInt32(self.blocksPerGroup - blocks)
                let freeInodesCount = UInt32(blockGroupSize.inodesPerGroup - inodes)
                groupDescriptors.append(
                    // low bits
                    GroupDescriptor(
                        blockBitmapLow: blockBitmap.lo,  // address of block bitmap
                        inodeBitmapLow: inodeBitmap.lo,  // address of inode bitmap
                        inodeTableLow: inodeTable.lo,  // address of inode table for this group
                        freeBlocksCountLow: freeBlocksCount.lo,
                        freeInodesCountLow: freeInodesCount.lo,
                        usedDirsCountLow: dirs.lo,
                        flags: 0x0000,
                        excludeBitmapLow: 0x0000_0000,
                        blockBitmapCsumLow: 0x0000,
                        inodeBitmapCsumLow: 0x0000,
                        itableUnusedLow: 0x0000,
                        checksum: 0x0000
                    ))
                totalBlocks += UInt32(blocks)
                totalInodes += UInt32(inodes)
            }

            // Since the bitmaps for unoccupied block groups are the same, there is no need
            // to allocate separate memory or storage for each individual bitmap.
            var blockBitmap: [UInt8] = .init(repeating: 0, count: Int(self.blocksPerGroup) / 8)
            var inodeBitmap: [UInt8] = .init(repeating: 0xff, count: Int(self.blocksPerGroup) / 8)
            for i in 0..<inodeTableSizePerGroup + 2 {
                blockBitmap[Int(i) / 8] |= 1 << (i % 8)
            }
            for i in 0..<UInt16(blockGroupSize.inodesPerGroup) {
                inodeBitmap[Int(i) / 8] &= ~(1 << (i % 8))
            }
            for group in blockGroupSize.blockGroups..<totalGroups.lo {
                var blocksInGroup = UInt32(self.blocksPerGroup)
                if group == totalGroups.lo {
                    if UInt64(self.size / UInt64(self.blockSize)) < self.blocksPerGroup {
                        break
                    }
                    blocksInGroup = UInt32((self.size / UInt64(self.blockSize)) % UInt64(self.blocksPerGroup))
                    if blocksInGroup == 0 {
                        break
                    }
                }
                let blockBitmapOffset = UInt64(group * self.blocksPerGroup + inodeTableSizePerGroup)
                let inodeBitmapOffset = UInt64(group * self.blocksPerGroup + inodeTableSizePerGroup + 1)
                let inodeTableOffset = UInt64(self.blocksPerGroup) * group
                let freeBlocksCount = UInt32(blocksInGroup - inodeTableSizePerGroup - 2)
                let freeInodesCount = UInt32(blockGroupSize.inodesPerGroup)
                groupDescriptors.append(
                    // low bits
                    GroupDescriptor(
                        blockBitmapLow: blockBitmapOffset.lo,  // address of block bitmap
                        inodeBitmapLow: inodeBitmapOffset.lo,  // address of inode bitmap
                        inodeTableLow: inodeTableOffset.lo,  // address of inode table for this group
                        freeBlocksCountLow: freeBlocksCount.lo,
                        freeInodesCountLow: freeInodesCount.lo,
                        usedDirsCountLow: 0,
                        flags: 0x0000,
                        excludeBitmapLow: 0x0000_0000,
                        blockBitmapCsumLow: 0x0000,
                        inodeBitmapCsumLow: 0x0000,
                        itableUnusedLow: 0x0000,
                        checksum: 0x0000
                    ))
                totalBlocks += (inodeTableSizePerGroup + 2)
                try self.seek(block: group * self.blocksPerGroup + inodeTableSizePerGroup)

                if group == totalGroups.lo {
                    var blockBitmapLo: [UInt8] = .init(repeating: 0, count: Int(self.blocksPerGroup) / 8)
                    for i in blocksInGroup..<UInt32(self.blocksPerGroup) {
                        blockBitmapLo[Int(i) / 8] |= 1 << (i % 8)
                    }
                    for i in 0..<inodeTableSizePerGroup + 2 {
                        blockBitmapLo[Int(i) / 8] |= 1 << (i % 8)
                    }
                    try self.handle.write(contentsOf: blockBitmapLo)
                    try self.handle.write(contentsOf: inodeBitmap)
                    continue
                }

                try self.handle.write(contentsOf: blockBitmap)
                try self.handle.write(contentsOf: inodeBitmap)
            }

            try self.seek(block: 1)

            for groupDescriptor in groupDescriptors {
                try withUnsafeLittleEndianBytes(of: groupDescriptor) { bytes in
                    try self.handle.write(contentsOf: bytes)
                }
            }
            // write superblock
            try self.seek(block: 0)
            try self.handle.write(contentsOf: Array<UInt8>.init(repeating: 0, count: 1024))

            let computedInodes = totalGroups * blockGroupSize.inodesPerGroup
            var blocksCount = totalGroups * self.blocksPerGroup
            while blocksCount < totalBlocks {
                blocksCount = UInt64(totalBlocks)
            }
            let totalFreeBlocks: UInt64
            if totalBlocks > blocksCount {
                totalFreeBlocks = 0
            } else {
                totalFreeBlocks = blocksCount - totalBlocks
            }
            var superblock = SuperBlock()
            superblock.inodesCount = computedInodes.lo
            superblock.blocksCountLow = blocksCount.lo
            superblock.blocksCountHigh = blocksCount.hi
            superblock.freeBlocksCountLow = totalFreeBlocks.lo
            superblock.freeBlocksCountHigh = totalFreeBlocks.hi
            let freeInodesCount = computedInodes.lo - totalInodes
            superblock.freeInodesCount = freeInodesCount
            superblock.firstDataBlock = 0
            superblock.logBlockSize = 2
            superblock.logClusterSize = 2
            superblock.blocksPerGroup = self.blocksPerGroup
            superblock.clustersPerGroup = self.blocksPerGroup
            superblock.inodesPerGroup = blockGroupSize.inodesPerGroup
            superblock.magic = EXT4.SuperBlockMagic
            superblock.state = 1  // cleanly unmounted
            superblock.errors = 1  // continue on error
            superblock.creatorOS = 3  // freeBSD
            superblock.revisionLevel = 1  // dynamic inode sizes
            superblock.firstInode = EXT4.FirstInode
            superblock.lpfInode = EXT4.LostAndFoundInode
            superblock.inodeSize = UInt16(EXT4.InodeSize)
            superblock.featureCompat = CompatFeature.sparseSuper2 | CompatFeature.extAttr
            superblock.featureIncompat =
                IncompatFeature.filetype | IncompatFeature.extents | IncompatFeature.flexBg
            superblock.featureRoCompat =
                RoCompatFeature.largeFile | RoCompatFeature.hugeFile | RoCompatFeature.extraIsize
            superblock.minExtraIsize = EXT4.ExtraIsize
            superblock.wantExtraIsize = EXT4.ExtraIsize
            superblock.logGroupsPerFlex = 31
            superblock.uuid = UUID().uuid
            try withUnsafeLittleEndianBytes(of: superblock) { bytes in
                try self.handle.write(contentsOf: bytes)
            }
            try self.handle.write(contentsOf: Array<UInt8>.init(repeating: 0, count: 2048))
        }

        // MARK: Private Methods and Properties
        private var handle: FileHandle
        private var inodes: [Ptr<Inode>]
        private var tree: FileTree
        private var deletedBlocks: [(start: UInt32, end: UInt32)] = []

        private var pos: UInt64 {
            guard let offset = try? self.handle.offset() else {
                return 0
            }
            return offset
        }

        private var currentBlock: UInt32 {
            self.pos / self.blockSize
        }

        private func seek(block: UInt32) throws {
            try self.handle.seek(toOffset: UInt64(block) * blockSize)
        }

        private func commitInodeTable(blockGroups: UInt32, inodesPerGroup: UInt32) throws -> UInt64 {
            // inodeTable must go into a new block
            if self.pos % blockSize != 0 {
                try seek(block: currentBlock + 1)
            }
            let inodeTableOffset = UInt64(currentBlock)

            let inodeSize = MemoryLayout<Inode>.size
            // Write InodeTable
            for inode in self.inodes {
                try withUnsafeLittleEndianBytes(of: inode.pointee) { bytes in
                    try handle.write(contentsOf: bytes)
                }
                try self.handle.write(
                    contentsOf: Array<UInt8>.init(repeating: 0, count: Int(EXT4.InodeSize) - inodeSize))
            }
            let tableSize: UInt64 = UInt64(EXT4.InodeSize) * blockGroups * inodesPerGroup
            let rest = tableSize - uint32(self.inodes.count) * EXT4.InodeSize
            let zeroBlock = Array<UInt8>.init(repeating: 0, count: Int(self.blockSize))
            for _ in 0..<(rest / self.blockSize) {
                try self.handle.write(contentsOf: zeroBlock)
            }
            try self.handle.write(contentsOf: Array<UInt8>.init(repeating: 0, count: Int(rest % self.blockSize)))
            return inodeTableOffset
        }

        // optimizes the distribution of blockGroups to obtain the lowest number of blockGroups needed to
        // represent all the inodes and all the blocks in the FS
        private func optimizeBlockGroupLayout(blocks: UInt32, inodes: UInt32) -> (
            blockGroups: UInt32, inodesPerGroup: UInt32
        ) {
            // counts the number of blockGroups given a particular inodesPerGroup size
            let groupCount: (_ blocks: UInt32, _ inodes: UInt32, _ inodesPerGroup: UInt32) -> UInt32 = {
                blocks, inodes, inodesPerGroup in
                let inodeBlocksPerGroup: UInt32 = inodesPerGroup * EXT4.InodeSize / self.blockSize
                let dataBlocksPerGroup: UInt32 = self.blocksPerGroup - inodeBlocksPerGroup - 2  // save room for the bitmaps
                // Increase the block count to ensure there are enough groups for all the inodes.
                let minBlocks: UInt32 = (inodes - 1) / inodesPerGroup * dataBlocksPerGroup + 1
                var updatedBlocks = blocks
                if blocks < minBlocks {
                    updatedBlocks = minBlocks
                }
                return (updatedBlocks + dataBlocksPerGroup - 1) / dataBlocksPerGroup
            }

            var groups: UInt32 = UInt32.max
            var inodesPerGroup: UInt32 = 0
            let inc = Int(self.blockSize * 512) / Int(EXT4.InodeSize)  // inodesPerGroup
            // minimizes the number of blockGroups needed to its lowest value
            for ipg in stride(from: inc, through: Int(self.maxInodesPerGroup), by: inc) {
                let g = groupCount(blocks, inodes, UInt32(ipg))
                if g < groups {
                    groups = g
                    inodesPerGroup = UInt32(ipg)
                }
            }
            return (groups, inodesPerGroup)
        }

        private func commit(_ parentPtr: Ptr<FileTree.FileTreeNode>?, _ nodePtr: Ptr<FileTree.FileTreeNode>) throws {
            let node = nodePtr.pointee
            let inodePtr = self.inodes[Int(node.inode) - 1]
            var inode = inodePtr.pointee
            guard inode.linksCount > 0 else {
                return
            }
            if node.link != nil {
                return
            }
            if self.pos % self.blockSize != 0 {
                try self.seek(block: self.currentBlock + 1)
            }
            if inode.mode.isDir() {
                let startBlock = self.currentBlock
                var left: Int = Int(self.blockSize)
                try writeDirEntry(name: ".", inode: node.inode, left: &left)
                if let parent = parentPtr {
                    try writeDirEntry(name: "..", inode: parent.pointee.inode, left: &left)
                } else {
                    try writeDirEntry(name: "..", inode: node.inode, left: &left)
                }
                var sortedChildren = Array(node.children)
                sortedChildren.sort { left, right in
                    left.pointee.inode < right.pointee.inode
                }
                for childPtr in sortedChildren {
                    let child = childPtr.pointee
                    try writeDirEntry(name: child.name, inode: child.inode, left: &left, link: child.link)
                }
                try finishDirEntryBlock(&left)
                let endBlock = self.currentBlock
                let size: UInt64 = UInt64(endBlock - startBlock) * self.blockSize
                inode.sizeLow = size.lo
                inode.sizeHigh = size.hi
                inodePtr.initialize(to: inode)
                node.blocks = (startBlock, endBlock)
                nodePtr.initialize(to: node)
                if self.pos % self.blockSize != 0 {
                    try self.seek(block: self.currentBlock + 1)
                }
                inode = try self.writeExtents(inode, (startBlock, endBlock))
                inodePtr.initialize(to: inode)
            }
        }

        private func fillExtents(
            node: inout ExtentLeafNode, numExtents: UInt32, numBlocks: UInt32, start: UInt32, offset: UInt32
        ) {
            for i in 0..<numExtents {
                let extentBlock: UInt32 = offset + i * EXT4.MaxBlocksPerExtent
                var length = numBlocks - extentBlock
                if length > EXT4.MaxBlocksPerExtent {
                    length = EXT4.MaxBlocksPerExtent
                }
                let extentStart: UInt32 = start + extentBlock
                let extent = ExtentLeaf(
                    block: extentBlock,
                    length: UInt16(length),
                    startHigh: 0,
                    startLow: extentStart
                )
                node.leaves.append(extent)
            }
        }

        private func writeExtents(_ inode: Inode, _ blocks: (start: UInt32, end: UInt32)) throws -> Inode {
            var inode = inode
            // rest of code assumes that extents MUST go into a new block
            if self.pos % self.blockSize != 0 {
                try self.seek(block: self.currentBlock + 1)
            }
            let dataBlocks = blocks.end - blocks.start
            let numExtents = (dataBlocks + EXT4.MaxBlocksPerExtent - 1) / EXT4.MaxBlocksPerExtent
            var usedBlocks = dataBlocks
            let extentNodeSize = 12
            let extentsPerBlock = self.blockSize / extentNodeSize - 1
            var blockData: [UInt8] = .init(repeating: 0, count: 60)
            var blockIndex: Int = 0
            switch numExtents {
            case 0:
                return inode  // noop
            case 1..<5:
                let extentHeader = ExtentHeader(
                    magic: EXT4.ExtentHeaderMagic,
                    entries: UInt16(numExtents),
                    max: 4,
                    depth: 0,
                    generation: 0)

                var node = ExtentLeafNode(header: extentHeader, leaves: [])
                fillExtents(node: &node, numExtents: numExtents, numBlocks: dataBlocks, start: blocks.start, offset: 0)
                withUnsafeLittleEndianBytes(of: node.header) { bytes in
                    for b in bytes {
                        blockData[blockIndex] = b
                        blockIndex = blockIndex + 1
                    }
                }
                for leaf in node.leaves {
                    withUnsafeLittleEndianBytes(of: leaf) { bytes in
                        for b in bytes {
                            blockData[blockIndex] = b
                            blockIndex = blockIndex + 1
                        }
                    }
                }
            case 5..<4 * UInt32(extentsPerBlock) + 1:
                let extentBlocks = numExtents / extentsPerBlock + 1
                usedBlocks += extentBlocks
                let extentHeader = ExtentHeader(
                    magic: EXT4.ExtentHeaderMagic,
                    entries: UInt16(extentBlocks),
                    max: 4,
                    depth: 1,
                    generation: 0
                )
                var root = ExtentIndexNode(header: extentHeader, indices: [])
                for i in 0..<extentBlocks {
                    if self.pos % self.blockSize != 0 {
                        try self.seek(block: self.currentBlock + 1)
                    }
                    let extentIdx = ExtentIndex(
                        block: i * extentsPerBlock * EXT4.MaxBlocksPerExtent,
                        leafLow: self.currentBlock,
                        leafHigh: 0,
                        unused: 0)
                    var extentsInBlock = numExtents - i * extentsPerBlock
                    if extentsInBlock > extentsPerBlock {
                        extentsInBlock = extentsPerBlock
                    }
                    let leafHeader = ExtentHeader(
                        magic: EXT4.ExtentHeaderMagic,
                        entries: UInt16(extentsInBlock),
                        max: UInt16(extentsPerBlock),
                        depth: 0,
                        generation: 0
                    )
                    var leafNode = ExtentLeafNode(header: leafHeader, leaves: [])
                    let offset = i * extentsPerBlock * EXT4.MaxBlocksPerExtent
                    fillExtents(
                        node: &leafNode, numExtents: extentsInBlock, numBlocks: dataBlocks,
                        start: blocks.start + offset,
                        offset: offset)
                    try withUnsafeLittleEndianBytes(of: leafNode.header) { bytes in
                        try self.handle.write(contentsOf: bytes)
                    }
                    for leaf in leafNode.leaves {
                        try withUnsafeLittleEndianBytes(of: leaf) { bytes in
                            try self.handle.write(contentsOf: bytes)
                        }
                    }
                    let extentTail = ExtentTail(checksum: leafNode.leaves.last!.block)
                    try withUnsafeLittleEndianBytes(of: extentTail) { bytes in
                        try self.handle.write(contentsOf: bytes)
                    }
                    root.indices.append(extentIdx)
                }
                withUnsafeLittleEndianBytes(of: root.header) { bytes in
                    for b in bytes {
                        blockData[blockIndex] = b
                        blockIndex = blockIndex + 1
                    }
                }
                for leaf in root.indices {
                    withUnsafeLittleEndianBytes(of: leaf) { bytes in
                        for b in bytes {
                            blockData[blockIndex] = b
                            blockIndex = blockIndex + 1
                        }
                    }
                }
            default:
                throw Error.fileTooBig(UInt64(dataBlocks) * self.blockSize)
            }
            inode.block = (
                blockData[0], blockData[1], blockData[2], blockData[3], blockData[4], blockData[5], blockData[6],
                blockData[7],
                blockData[8], blockData[9],
                blockData[10], blockData[11], blockData[12], blockData[13], blockData[14], blockData[15], blockData[16],
                blockData[17], blockData[18], blockData[19],
                blockData[20], blockData[21], blockData[22], blockData[23], blockData[24], blockData[25], blockData[26],
                blockData[27], blockData[28], blockData[29],
                blockData[30], blockData[31], blockData[32], blockData[33], blockData[34], blockData[35], blockData[36],
                blockData[37], blockData[38], blockData[39],
                blockData[40], blockData[41], blockData[42], blockData[43], blockData[44], blockData[45], blockData[46],
                blockData[47], blockData[48], blockData[49],
                blockData[50], blockData[51], blockData[52], blockData[53], blockData[54], blockData[55], blockData[56],
                blockData[57], blockData[58], blockData[59]
            )
            // ensure that inode's block count includes extent blocks
            inode.blocksLow += usedBlocks
            inode.flags = InodeFlag.extents | inode.flags
            return inode
        }
        // writes a single directory entry
        private func writeDirEntry(name: String, inode: InodeNumber, left: inout Int, link: InodeNumber? = nil) throws {
            guard self.inodes[Int(inode) - 1].pointee.linksCount > 0 else {
                return
            }
            guard let nameData = name.data(using: .utf8) else {
                throw Error.invalidName(name)
            }
            let directoryEntrySize = MemoryLayout<DirectoryEntry>.size
            let rlb = directoryEntrySize + nameData.count
            let rl = (rlb + 3) & ~3
            if left < rl + 12 {
                try self.finishDirEntryBlock(&left)
            }
            var mode = self.inodes[Int(inode) - 1].pointee.mode
            var inodeNum = inode
            if let link {
                mode = self.inodes[Int(link) - 1].pointee.mode | 0o777
                inodeNum = link
            }
            let entry = DirectoryEntry(
                inode: inodeNum,
                recordLength: UInt16(rl),
                nameLength: UInt8(nameData.count),
                fileType: mode.fileType()
            )
            try withUnsafeLittleEndianBytes(of: entry) { bytes in
                try self.handle.write(contentsOf: bytes)
            }

            try nameData.withUnsafeBytes { buffer in
                try withUnsafeLittleEndianBuffer(of: buffer) { b in
                    try self.handle.write(contentsOf: b)
                }
            }
            try self.handle.write(contentsOf: [UInt8](repeating: 0, count: rl - rlb))
            left = left - rl
        }

        private func finishDirEntryBlock(_ left: inout Int) throws {
            defer { left = Int(self.blockSize) }
            if left <= 0 {
                return
            }
            let entry = DirectoryEntry(
                inode: InodeNumber(0),
                recordLength: UInt16(left),
                nameLength: 0,
                fileType: 0
            )
            try withUnsafeLittleEndianBytes(of: entry) { bytes in
                try self.handle.write(contentsOf: bytes)
            }
            left = left - MemoryLayout<DirectoryEntry>.size
            if left < 4 {
                throw Error.noSpaceForTrailingDEntry
            }
            try self.handle.write(contentsOf: [UInt8](repeating: 0, count: Int(left)))
        }

        public enum Error: Swift.Error, CustomStringConvertible, Sendable, Equatable {
            case notDirectory(_ path: FilePath)
            case notFile(_ path: FilePath)
            case notFound(_ path: FilePath)
            case alreadyExists(_ path: FilePath)
            case unsupportedFiletype
            case maximumLinksExceeded(_ path: FilePath)
            case fileTooBig(_ size: UInt64)
            case invalidLink(_ path: FilePath)
            case invalidName(_ name: String)
            case noSpaceForTrailingDEntry
            case insufficientSpaceForGroupDescriptorBlocks
            case cannotCreateHardlinksToDirTarget(_ path: FilePath)
            case cannotTruncateFile(_ path: FilePath)
            case cannotCreateSparseFile(_ path: FilePath)
            case cannotResizeFS(_ size: UInt64)
            public var description: String {
                switch self {
                case .notDirectory(let path):
                    return "\(path) is not a directory"
                case .notFile(let path):
                    return "\(path) is not a file"
                case .notFound(let path):
                    return "\(path) not found"
                case .alreadyExists(let path):
                    return "\(path) already exists"
                case .unsupportedFiletype:
                    return "file type not supported"
                case .maximumLinksExceeded(let path):
                    return "maximum links exceeded for path: \(path)"
                case .fileTooBig(let size):
                    return "\(size) exceeds max file size (128 GiB)"
                case .invalidLink(let path):
                    return "'\(path)' is an invalid link"
                case .invalidName(let name):
                    return "'\(name)' is an invalid name"
                case .noSpaceForTrailingDEntry:
                    return "not enough space for trailing dentry"
                case .insufficientSpaceForGroupDescriptorBlocks:
                    return "not enough space for group descriptor blocks"
                case .cannotCreateHardlinksToDirTarget(let path):
                    return "cannot create hard links to directory target: \(path)"
                case .cannotTruncateFile(let path):
                    return "cannot truncate file: \(path)"
                case .cannotCreateSparseFile(let path):
                    return "cannot create sparse file at \(path)"
                case .cannotResizeFS(let size):
                    return "cannot resize fs to \(size) bytes"
                }
            }
        }

        deinit {
            for inode in inodes {
                inode.deinitialize(count: 1)
                inode.deallocate()
            }
            self.inodes.removeAll()
        }
    }
}

extension Date {
    func fs() -> UInt64 {
        if self == Date.distantPast {
            return 0
        }

        let s = self.timeIntervalSince1970

        if s < -0x8000_0000 {
            return 0x8000_0000
        }

        if s > 0x3_7fff_ffff {
            return 0x3_7fff_ffff
        }

        let seconds = UInt64(s)
        let nanoseconds = UInt64(self.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1_000_000_000)

        return seconds | (nanoseconds << 34)
    }
}
