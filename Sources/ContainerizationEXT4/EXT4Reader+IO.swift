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

extension EXT4 {
    public enum PathIOError: Swift.Error, CustomStringConvertible {
        case notFound(String)
        case notAFile(String)
        case isDirectory(String)
        case notADirectory(String)
        case symlinkLoop(String)
        case invalidPath(String)

        public var description: String {
            switch self {
            case .notFound(let p): return "no such file or directory: \(p)"
            case .notAFile(let p): return "not a regular file: \(p)"
            case .isDirectory(let p): return "is a directory: \(p)"
            case .notADirectory(let p): return "not a directory: \(p)"
            case .symlinkLoop(let p): return "symlink loop while resolving: \(p)"
            case .invalidPath(let p): return "invalid path: \(p)"
            }
        }
    }
}

// MARK: - Public API

extension EXT4.EXT4Reader {
    /// Return true if a path exists (file or directory) in this ext4 device.
    public func exists(_ path: FilePath, followSymlinks: Bool = true) -> Bool {
        (try? resolvePath(path, followSymlinks: followSymlinks).inode) != nil
    }

    /// Get the total number of blocks in the filesystem
    private var totalBlocks: UInt64 {
        let lo = UInt64(_superBlock.blocksCountLow)
        let hi = UInt64(_superBlock.blocksCountHigh)
        return lo | (hi << 32)
    }

    /// Validate that a physical block address is within device bounds
    private func validateBlockAddress(_ block: UInt32) throws {
        guard UInt64(block) < totalBlocks else {
            throw EXT4.PathIOError.invalidPath("block address \(block) exceeds device bounds (\(totalBlocks) blocks)")
        }
    }

    /// Metadata (inode + inode number) for a path.
    public func stat(_ path: FilePath, followSymlinks: Bool = true) throws -> (inodeNumber: EXT4.InodeNumber, inode: EXT4.Inode) {
        let resolved = try resolvePath(path, followSymlinks: followSymlinks)
        return (resolved.inodeNum, try getInode(number: resolved.inodeNum))
    }

    /// List a directory's entries (names only). Does not include "." or "..".
    public func listDirectory(_ path: FilePath) throws -> [String] {
        let (inoNum, ino) = try stat(path)
        guard ino.mode.isDir() else {
            throw EXT4.PathIOError.notADirectory(path.description)
        }
        let children = try children(of: inoNum)
        return
            children
            .map { $0.0 }
            .filter { $0 != "." && $0 != ".." }
            .sorted()
    }

    /// Read bytes from a regular file at `path` into `buffer`, starting at `offset`.
    /// Returns the number of bytes written to `buffer` (may be less than `buffer.count` at EOF).
    /// - Note: Semantics mirror `read(2)`: partial reads are possible.
    @discardableResult
    public func readFile(
        at path: FilePath,
        into buffer: UnsafeMutableRawBufferPointer,
        offset: UInt64 = 0,
        followSymlinks: Bool = true
    ) throws -> Int {
        let context = try prepareRead(path: path, offset: offset, followSymlinks: followSymlinks)
        if buffer.count == 0 || context.maxReadable == 0 {
            return 0
        }

        let want = min(UInt64(buffer.count), context.maxReadable)
        return try performRead(
            inodeNumber: context.inodeNumber,
            start: context.start,
            wantedBytes: want,
            into: buffer
        )
    }

    /// Read bytes from a regular file at `path` starting at `offset`.
    /// If `count` is nil, reads to EOF. Returns exactly the requested bytes (or less at EOF).
    public func readFile(
        at path: FilePath,
        offset: UInt64 = 0,
        count: Int? = nil,
        followSymlinks: Bool = true
    ) throws -> Data {
        let context = try prepareRead(path: path, offset: offset, followSymlinks: followSymlinks)
        let want = count.map { min(UInt64($0), context.maxReadable) } ?? context.maxReadable
        if want == 0 {
            return Data()
        }

        var out = Data(count: Int(want))
        let wrote = try out.withUnsafeMutableBytes {
            try performRead(
                inodeNumber: context.inodeNumber,
                start: context.start,
                wantedBytes: want,
                into: $0
            )
        }
        if wrote < Int(want) {
            out.removeSubrange(wrote..<Int(want))
        }
        return out
    }

    private func prepareRead(
        path: FilePath,
        offset: UInt64,
        followSymlinks: Bool
    ) throws -> (inodeNumber: EXT4.InodeNumber, start: UInt64, maxReadable: UInt64) {
        let (inoNum, inode) = try stat(path, followSymlinks: followSymlinks)

        if inode.mode.isDir() {
            throw EXT4.PathIOError.isDirectory(path.description)
        }

        if !inode.mode.isReg() {
            throw EXT4.PathIOError.notAFile(path.description)
        }

        let fileSize: UInt64 = inodeFileSize(inode)
        let start = min(offset, fileSize)
        let maxReadable = fileSize - start
        return (inodeNumber: inoNum, start: start, maxReadable: maxReadable)
    }

    private func performRead(
        inodeNumber: EXT4.InodeNumber,
        start: UInt64,
        wantedBytes: UInt64,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        if wantedBytes == 0 {
            return 0
        }

        guard let extents = try self.getExtents(inode: inodeNumber), !extents.isEmpty else {
            return 0
        }

        for (physStartBlk, physEndBlk) in extents {
            try validateBlockAddress(physStartBlk)
            if physEndBlk > physStartBlk {
                try validateBlockAddress(physEndBlk - 1)
            }
        }

        guard let base = buffer.baseAddress else {
            return 0
        }

        let desiredBytes = Int(min(wantedBytes, UInt64(buffer.count)))
        if desiredBytes == 0 {
            return 0
        }

        let blockSizeBytes = self.blockSize
        let reqStart = start
        let reqEnd = start + UInt64(desiredBytes)
        var logicalOffset: UInt64 = 0
        var bytesWritten = 0

        for (physStartBlk, physEndBlk) in extents {
            let extentBytes = UInt64(physEndBlk - physStartBlk) * blockSizeBytes
            let logicalEnd = logicalOffset + extentBytes

            if logicalEnd <= reqStart {
                logicalOffset = logicalEnd
                continue
            }
            if logicalOffset >= reqEnd {
                break
            }

            let overlapStart = max(logicalOffset, reqStart)
            let overlapEnd = min(logicalEnd, reqEnd)
            var remaining = overlapEnd - overlapStart
            if remaining == 0 {
                logicalOffset = logicalEnd
                continue
            }

            let offsetIntoExtent = overlapStart - logicalOffset
            let absoluteByteOffset = (UInt64(physStartBlk) * blockSizeBytes) + offsetIntoExtent

            do {
                try self.handle.seek(toOffset: absoluteByteOffset)
            } catch {
                if bytesWritten > 0 {
                    return bytesWritten
                }
                throw EXT4.PathIOError.invalidPath("failed to seek to offset \(absoluteByteOffset): \(error)")
            }

            while remaining > 0 && bytesWritten < desiredBytes {
                let chunk = min(desiredBytes - bytesWritten, Int(min(remaining, UInt64(1 << 20))))
                let dest = UnsafeMutableRawBufferPointer(
                    start: base.advanced(by: bytesWritten),
                    count: chunk
                )

                do {
                    guard let data = try self.handle.read(upToCount: chunk) else {
                        return bytesWritten
                    }

                    if data.count == 0 {
                        return bytesWritten
                    }

                    // Copy the data to the destination buffer
                    data.withUnsafeBytes { sourceBytes in
                        dest.copyMemory(from: UnsafeRawBufferPointer(sourceBytes))
                    }

                    bytesWritten += data.count
                    remaining -= UInt64(data.count)

                    if data.count < chunk && remaining > 0 {
                        return bytesWritten
                    }
                } catch {
                    if bytesWritten > 0 {
                        return bytesWritten
                    }
                    throw error
                }
            }

            logicalOffset = logicalEnd
            if bytesWritten >= desiredBytes {
                break
            }
        }

        return bytesWritten
    }

    // MARK: - Internals inside EXT4Reader
    public struct ResolvedPath {
        let inodeNum: EXT4.InodeNumber
        let inode: EXT4.Inode
    }

    /// Resolve a path to an inode (optionally following symlinks).
    /// Paths may be absolute ("/...") or relative (from "/").
    public func resolvePath(_ path: FilePath, followSymlinks: Bool, maxSymlinks: Int = 40) throws -> ResolvedPath {
        var components: [String] = normalize(path: path)
        var current: EXT4.InodeNumber = EXT4.RootInode
        var parentStack: [EXT4.InodeNumber] = []  // Track parent chain for proper ".." handling

        var symlinkHops = 0
        var visitedInodes = Set<EXT4.InodeNumber>()

        // Process components one at a time to handle symlinks in the middle of paths
        var componentIndex = 0

        while componentIndex < components.count {
            let name = components[componentIndex]

            if name == "." {
                componentIndex += 1
                continue
            }

            if name == ".." {
                // Handle parent directory traversal
                if current == EXT4.RootInode {
                    // At root, ".." points to itself
                    componentIndex += 1
                    continue
                }

                // Use parent stack if available
                if !parentStack.isEmpty {
                    current = parentStack.removeLast()
                } else {
                    // Fallback: look up ".." entry in filesystem
                    let entries = try children(of: current)
                    if let parent = entries.first(where: { $0.0 == ".." })?.1 {
                        current = parent
                    }
                }
                componentIndex += 1
                continue
            }

            // Regular component: verify current is a directory and look up child
            let currentInode = try getInode(number: current)
            guard currentInode.mode.isDir() else {
                throw EXT4.PathIOError.notADirectory(name)
            }

            let entries = try children(of: current)
            guard let child = entries.first(where: { $0.0 == name }) else {
                throw EXT4.PathIOError.notFound(name)
            }

            // Check if child is a symlink
            let childInode = try getInode(number: child.1)
            if childInode.mode.isLink() && followSymlinks {
                // Check for symlink loop
                if visitedInodes.contains(child.1) {
                    throw EXT4.PathIOError.symlinkLoop(FilePath(components.joined(separator: "/")).description)
                }
                visitedInodes.insert(child.1)

                // Enforce max symlink depth
                symlinkHops += 1
                if symlinkHops > maxSymlinks {
                    throw EXT4.PathIOError.symlinkLoop(FilePath(components.joined(separator: "/")).description)
                }

                // Read symlink target
                let linkBytes = try readFileFromInode(inodeNum: child.1)
                guard let linkTarget = String(data: linkBytes, encoding: .utf8), !linkTarget.isEmpty else {
                    throw EXT4.PathIOError.invalidPath("empty symlink target")
                }

                // Parse symlink target into components
                let targetComponents = normalize(path: FilePath(linkTarget))

                // Replace current component with symlink target components and continue
                if linkTarget.hasPrefix("/") {
                    // Absolute symlink: reset to root
                    current = EXT4.RootInode
                    parentStack = []
                    // Replace the symlink component with target components + remaining path
                    components = targetComponents + Array(components[(componentIndex + 1)...])
                    componentIndex = 0  // Start from beginning with new path
                } else {
                    // Relative symlink: continue from current directory
                    // Replace the symlink component with target components + remaining path
                    components = Array(components[0..<componentIndex]) + targetComponents + Array(components[(componentIndex + 1)...])
                    // Don't change componentIndex - continue from same position with expanded path
                }
            } else {
                // Not a symlink or not following symlinks - descend into directory
                parentStack.append(current)
                current = child.1
                componentIndex += 1
            }
        }

        // All components processed - return final inode
        let finalInode = try getInode(number: current)
        return ResolvedPath(inodeNum: current, inode: finalInode)
    }

    /// Walk a sequence of path components from a starting inode with parent tracking.
    /// Returns the final inode and updated parent stack.
    private func walkWithParents(
        current start: EXT4.InodeNumber,
        components: [String],
        parentStack initialStack: [EXT4.InodeNumber]
    ) throws -> (EXT4.InodeNumber, [EXT4.InodeNumber]) {
        var current = start
        var parentStack = initialStack

        if components.isEmpty { return (current, parentStack) }

        for name in components {
            if name == "." {
                continue
            }

            if name == ".." {
                // Handle parent directory traversal with proper tracking
                if current == EXT4.RootInode {
                    // At root, ".." points to itself (POSIX behavior)
                    continue
                }

                // Use parent stack if available for accurate traversal
                if !parentStack.isEmpty {
                    current = parentStack.removeLast()
                } else {
                    // No parent tracking available - look up ".." entry in filesystem
                    // This happens when we start traversal from a non-root inode
                    let entries = try children(of: current)
                    if let parent = entries.first(where: { $0.0 == ".." })?.1 {
                        current = parent
                    }
                }
                continue
            }

            // Regular component: verify current is a directory before traversing
            let currentInode = try getInode(number: current)
            guard currentInode.mode.isDir() else {
                throw EXT4.PathIOError.notADirectory(name)
            }

            // Look up child in current directory
            let entries = try children(of: current)
            guard let child = entries.first(where: { $0.0 == name }) else {
                throw EXT4.PathIOError.notFound(name)
            }

            // Push current to parent stack before descending
            parentStack.append(current)
            current = child.1
        }

        return (current, parentStack)
    }

    /// Walk a sequence of path components from a starting inode.
    private func walk(current start: EXT4.InodeNumber, components: [String]) throws -> EXT4.InodeNumber {
        let (result, _) = try walkWithParents(current: start, components: components, parentStack: [])
        return result
    }

    /// Normalize a path into components, handling absolute and relative paths.
    private func normalize(path: FilePath) -> [String] {
        let s = path.description
        let trimmed = s.hasPrefix("/") ? String(s.dropFirst()) : s
        if trimmed.isEmpty { return [] }
        return trimmed.split(separator: "/").map(String.init)
    }

    /// Read entire file content of a regular file given an inode (used for symlink targets).
    private func readFileFromInode(inodeNum: EXT4.InodeNumber) throws -> Data {
        let ino = try getInode(number: inodeNum)
        guard ino.mode.isReg() || ino.mode.isLink() else {
            return Data()
        }
        let size = inodeFileSize(ino)
        if size == 0 { return Data() }

        // Handle fast symlinks (target stored directly in inode block field)
        if ino.mode.isLink() && size < 60 {
            // Extract target from inode block field
            let blockData = withUnsafeBytes(of: ino.block) { Data($0) }
            return blockData.prefix(Int(size))
        }

        return try readFileBytesFromExtents(inodeNum: inodeNum, offset: 0, count: size)
    }

    /// Low-level read using extents, with explicit offset & length (in bytes).
    private func readFileBytesFromExtents(inodeNum: EXT4.InodeNumber, offset: UInt64, count: UInt64) throws -> Data {
        guard let extents = try self.getExtents(inode: inodeNum), !extents.isEmpty else {
            return Data()
        }

        // Validate all extent blocks are within device bounds
        for (startBlk, endBlk) in extents {
            try validateBlockAddress(startBlk)
            if endBlk > startBlk {
                try validateBlockAddress(endBlk - 1)
            }
        }

        var out = Data(capacity: Int(count))
        var logicalOffset: UInt64 = 0
        var bytesReadSuccessfully: Int = 0
        let reqStart = offset
        let reqEnd = offset + count
        let bs = self.blockSize

        for (startBlk, endBlk) in extents {
            let extentBytes = UInt64(endBlk - startBlk) * bs
            let logicalEnd = logicalOffset + extentBytes
            if logicalEnd <= reqStart {
                logicalOffset = logicalEnd
                continue
            }
            if logicalOffset >= reqEnd { break }

            let ovlStart = max(logicalOffset, reqStart)
            let ovlEnd = min(logicalEnd, reqEnd)
            let ovlLen = ovlEnd - ovlStart
            if ovlLen == 0 {
                logicalOffset = logicalEnd
                continue
            }

            let offsetIntoExtent = ovlStart - logicalOffset
            let absByteOffset = UInt64(startBlk) * bs + offsetIntoExtent

            do {
                try self.handle.seek(toOffset: absByteOffset)
            } catch {
                if bytesReadSuccessfully > 0 {
                    // Return partial data that was successfully read
                    return out
                }
                throw EXT4.PathIOError.invalidPath("failed to seek to offset \(absByteOffset): \(error)")
            }

            var left = ovlLen
            while left > 0 {
                let chunk = Int(min(left, 1 << 20))

                do {
                    guard let data = try self.handle.read(upToCount: chunk) else {
                        let blk = UInt32(absByteOffset / bs)
                        throw EXT4.Error.couldNotReadBlock(blk)
                    }

                    out.append(data)
                    bytesReadSuccessfully += data.count
                    left -= UInt64(data.count)

                    if data.count < chunk && left > 0 {
                        // Partial read - return what we have
                        return out
                    }
                } catch {
                    if bytesReadSuccessfully > 0 {
                        // Return partial data on error
                        return out
                    }
                    throw error
                }
            }
            logicalOffset = logicalEnd
            if out.count >= Int(count) { break }
        }
        if out.count > Int(count) { out.removeSubrange(Int(count)..<out.count) }
        return out
    }

    /// Compute 64-bit file size from the inode fields (i_size).
    /// ext4 stores low 32 bits in i_size_lo and the high 32 bits in i_size_high when 64-bit sizes are enabled.
    private func inodeFileSize(_ inode: EXT4.Inode) -> UInt64 {
        // The Containerization EXT4 Inode struct exposes mode and block fields; size fields
        // are commonly named sizeLo/sizeHigh in this codebase.
        // EXT4 supports 64-bit file sizes - always use both low and high parts.
        let lo = UInt64(inode.sizeLow)
        let hi = UInt64(inode.sizeHigh)
        return lo | (hi << 32)
    }
}
