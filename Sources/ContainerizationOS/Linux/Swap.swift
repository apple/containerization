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

import CShim
import ContainerizationError

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// `Swap` is a utility type that contains static helpers for creating a swap
/// file and enabling it as swap space for the guest.
///
/// The swap area header layout is the kernel's on-disk format, version 1:
/// a page of header whose last 10 bytes are the magic `SWAPSPACE2`, with the
/// version, the last usable page and the page count at fixed offsets from the
/// start of the second kilobyte.
/// https://docs.kernel.org/admin-guide/mm/concepts.html
/// https://github.com/torvalds/linux/blob/master/include/linux/swap.h
public struct Swap: Sendable {
    /// Offset of the version field within the swap header, and of the last
    /// usable page field that follows it.
    private static let versionOffset = 1024
    private static let lastPageOffset = 1028
    /// The magic that marks the last bytes of the first page of a swap area.
    private static let magic = "SWAPSPACE2"
    /// The queue attributes the kernel exposes for each block device.
    public static let blockPath = "/sys/block"

    /// Mount type that marks a block device as a container's swap area, which
    /// the agent enables rather than mounts. It travels in the `type` field of
    /// the mount the host sends, so both sides read it from here.
    ///
    /// Kata gives its guest swap the same shape, the host attaching a raw file
    /// as a block device and the agent calling `swapon` on it, and carries the
    /// request on an RPC of its own (`AddSwap`). Here it travels as a mount so
    /// the device path the VMM allocates reaches the guest the way every other
    /// attached device's does.
    /// https://github.com/kata-containers/kata-containers/blob/main/src/agent/src/rpc.rs
    public static let mountType = "swap"

    #if os(Linux)
    /// Format the swap area at `path` and enable it.
    ///
    /// `path` may be a block device or a file that already has its final size,
    /// which is what `size` describes; `create` makes such a file.
    public static func enable(path: String, size: UInt64, pageSize: Int = 4096) throws {
        try format(path: path, size: size, pageSize: pageSize)
        try on(path: path)
    }

    /// Write the swap area header the kernel expects to an existing block
    /// device or fully allocated file.
    ///
    /// This is what `mkswap` writes, and kata has its host run `mkswap` before
    /// attaching the device. That is not open to a host which is not Linux, so
    /// the header is written here instead, from the guest that is about to
    /// enable it.
    /// https://github.com/kata-containers/kata-containers/blob/main/src/runtime-rs/crates/resource/src/cpu_mem/swap.rs
    public static func format(path: String, size: UInt64, pageSize: Int = 4096) throws {
        let pages = size / UInt64(pageSize)
        guard pages > 1 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "swap size \(size) is smaller than the two pages a swap area needs"
            )
        }
        // The header carries the last page number in 32 bits.
        guard let lastPage = UInt32(exactly: pages - 1) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "swap size \(size) exceeds the \(UInt64(UInt32.max) + 1) pages a swap header can carry"
            )
        }

        let fd = open(path, O_WRONLY)
        guard fd >= 0 else {
            throw POSIXError.fromErrno()
        }
        defer { close(fd) }

        var header = [UInt8](repeating: 0, count: pageSize)
        header.replaceSubrange(versionOffset..<(versionOffset + 4), with: littleEndianBytes(1))
        header.replaceSubrange(
            lastPageOffset..<(lastPageOffset + 4),
            with: littleEndianBytes(lastPage)
        )
        // The magic occupies the last bytes of the header page.
        header.replaceSubrange((pageSize - magic.count)..<pageSize, with: Array(magic.utf8))

        let written = header.withUnsafeBytes { buffer in
            pwrite(fd, buffer.baseAddress, buffer.count, 0)
        }
        guard written == pageSize else {
            throw POSIXError.fromErrno()
        }
    }

    /// Size in bytes of the block device or file at `path`.
    public static func size(ofDeviceAt path: String) throws -> UInt64 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError.fromErrno()
        }
        defer { close(fd) }
        let end = lseek(fd, 0, SEEK_END)
        guard end > 0 else {
            throw POSIXError.fromErrno()
        }
        return UInt64(end)
    }

    /// Enable the swap area at `path`, asking the kernel to discard the blocks
    /// it stops using so the file backing the area does not keep them.
    ///
    /// Ours: kata enables its swap with no flags, which suits an area on a
    /// host disk that was sized once and stays that size.
    /// https://github.com/kata-containers/kata-containers/blob/main/src/agent/src/rpc.rs
    public static func on(path: String) throws {
        try markSolidState(devicePath: path)
        guard CZ_swapon(path, CZ_SWAP_DISCARD | CZ_SWAP_DISCARD_PAGES) == 0 else {
            throw POSIXError.fromErrno()
        }
    }

    /// Mark the block device backing the swap area as non rotational.
    ///
    /// Ours: no other runtime does this, because no other runtime needs the
    /// area to give its blocks back. Kata calls `swapon` with no flags at all.
    ///
    /// The kernel only tracks a swap area in clusters when its device is non
    /// rotational, and freeing a cluster is the only thing that schedules a
    /// discard. A virtio block device reports as rotational, so without this
    /// the area is scanned rather than clustered and the discard flags above
    /// never take effect, leaving the file that backs the area holding every
    /// block the guest has ever swapped to.
    /// https://github.com/torvalds/linux/blob/master/mm/swapfile.c
    static func markSolidState(devicePath: String) throws {
        let device = URL(fileURLWithPath: devicePath).lastPathComponent
        try "0".write(
            to: URL(fileURLWithPath: Self.blockPath)
                .appendingPathComponent(device)
                .appendingPathComponent("queue")
                .appendingPathComponent("rotational"),
            atomically: false,
            encoding: .ascii
        )
    }

    private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    #endif  // os(Linux)
}
