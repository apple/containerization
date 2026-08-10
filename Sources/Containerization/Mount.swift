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

import ContainerizationError
import Foundation

#if os(macOS)
import Virtualization
#endif

#if os(Linux)
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
#endif

/// A filesystem mount exposed to a container.
public struct Mount: Sendable {
    /// The filesystem or mount type. This is the string
    /// that will be used for the mount syscall itself.
    public var type: String
    /// The source path of the mount.
    public var source: String
    /// The destination path of the mount.
    public var destination: String
    /// Filesystem or mount specific options.
    public var options: [String]
    /// Runtime specific options. This can be used
    /// as a way to discern what kind of device a vmm
    /// should create for this specific mount (virtioblock
    /// virtiofs etc.).
    public let runtimeOptions: RuntimeOptions

    /// A type representing a "hint" of what type
    /// of mount this really is (block, directory, purely
    /// guest mount) and a set of type specific options, if any.
    public enum RuntimeOptions: Sendable {
        case virtioblk([String])
        case virtiofs([String])
        case shared
        case any([String])
    }

    public init(
        type: String,
        source: String,
        destination: String,
        options: [String],
        runtimeOptions: RuntimeOptions
    ) {
        self.type = type
        self.source = source
        self.destination = destination
        self.options = options
        self.runtimeOptions = runtimeOptions
    }

    /// Mount representing a virtio block device.
    public static func block(
        format: String,
        source: String,
        destination: String,
        options: [String] = [],
        runtimeOptions: [String] = []
    ) -> Self {
        .init(
            type: format,
            source: source,
            destination: destination,
            options: options,
            runtimeOptions: .virtioblk(runtimeOptions)
        )
    }

    /// Mount representing a virtiofs share.
    public static func share(
        source: String,
        destination: String,
        options: [String] = [],
        runtimeOptions: [String] = []
    ) -> Self {
        .init(
            type: "virtiofs",
            source: source,
            destination: destination,
            options: options,
            runtimeOptions: .virtiofs(runtimeOptions)
        )
    }

    /// A generic mount.
    public static func any(
        type: String,
        source: String,
        destination: String,
        options: [String] = [],
        runtimeOptions: [String] = []
    ) -> Self {
        .init(
            type: type,
            source: source,
            destination: destination,
            options: options,
            runtimeOptions: .any(runtimeOptions)
        )
    }

    /// A mount referencing a shared pod volume by name.
    public static func sharedMount(
        name: String,
        destination: String,
        options: [String] = []
    ) -> Self {
        .init(
            type: "none",
            source: name,
            destination: destination,
            options: options,
            runtimeOptions: .shared
        )
    }

    /// Clone the Mount to the provided path.
    ///
    /// On macOS this uses `clonefile` (via `FileManager.copyItem`) for a
    /// copy-on-write copy when the underlying filesystem supports it. On
    /// Linux it tries `ioctl(FICLONE)` first (CoW on btrfs / xfs / bcachefs)
    /// and falls back to a `SEEK_DATA`/`SEEK_HOLE` sparse copy that copies
    /// only data ranges. This matters for EXT4 images produced by
    /// `EXT4+Formatter`, which sparse-allocate via `lseek + 1-byte write` —
    /// a non-sparse copy would inflate a ~50 MB alpine rootfs into a
    /// fully-allocated 2 GiB clone and exhaust the integration suite's
    /// writable layer in ~30 tests.
    public func clone(to: String) throws -> Self {
        #if os(Linux)
        try Self.linuxSparseCopy(from: self.source, to: to)
        #else
        try FileManager.default.copyItem(atPath: self.source, toPath: to)
        #endif

        return .init(
            type: self.type,
            source: to,
            destination: self.destination,
            options: self.options,
            runtimeOptions: self.runtimeOptions
        )
    }

    #if os(Linux)
    /// Copy `src` to `dst`, preferring a CoW reflink (`ioctl(FICLONE)`) and
    /// falling back to a SEEK_DATA/SEEK_HOLE sparse copy. The reflink path
    /// succeeds on btrfs / xfs (`reflink=1`) / bcachefs; on ext4 / tmpfs /
    /// overlayfs it fails fast with EOPNOTSUPP/EXDEV/EINVAL and we walk
    /// the hole map instead. The sparse-copy path also handles
    /// filesystems that don't support hole-seeking (the very first
    /// SEEK_DATA returns EINVAL) by copying the remainder verbatim. Mode
    /// bits are preserved from the source.
    private static func linuxSparseCopy(from src: String, to dst: String) throws {
        // Stable Linux ABI since 3.1 (ext4, tmpfs, overlayfs all support it).
        // Re-declared here so the build doesn't depend on whether the
        // Glibc/Musl Swift overlay re-exports them.
        let SEEK_DATA: Int32 = 3
        let SEEK_HOLE: Int32 = 4
        // _IOW(0x94, 9, int) on every Linux arch we target (x86_64, aarch64).
        let FICLONE: CUnsignedLong = 0x4004_9409

        let srcFd = open(src, O_RDONLY | O_CLOEXEC)
        guard srcFd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = close(srcFd) }

        var st = stat()
        guard fstat(srcFd, &st) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let size = off_t(st.st_size)
        let mode = mode_t(st.st_mode & 0o7777)

        let dstFd = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
        guard dstFd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = close(dstFd) }

        // FICLONE atomically replaces dst's contents with a CoW clone of
        // src — sets size and contents in one shot, no ftruncate needed
        // afterwards. On failure FICLONE guarantees dst is untouched, so
        // we can safely fall through to the sparse-copy path. ioctl(2) is
        // variadic; type-pun via a fixed-arity function pointer (same
        // pattern as ContainerizationOS.Socket).
        let ioctlFICLONE: @convention(c) (CInt, CUnsignedLong, CInt) -> CInt = ioctl
        if ioctlFICLONE(dstFd, FICLONE, srcFd) == 0 {
            return
        }

        // Set the destination size up front so any trailing hole survives —
        // we only ever pwrite data ranges, never zero-fill.
        guard ftruncate(dstFd, size) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let bufSize = 1 << 20  // 1 MiB
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        var pos: off_t = 0
        while pos < size {
            let dataStart = lseek(srcFd, pos, SEEK_DATA)
            if dataStart < 0 {
                // ENXIO: no more data — rest is hole, already covered by ftruncate.
                if errno == ENXIO {
                    break
                }
                // EINVAL/ENOTSUP: filesystem doesn't support SEEK_DATA. Treat
                // the remainder as one big data range and copy it verbatim.
                try Self.copyRange(srcFd: srcFd, dstFd: dstFd, start: pos, end: size, buf: buf, bufSize: bufSize)
                break
            }

            // SEEK_HOLE returns end-of-file when there's no trailing hole.
            let dataEnd = lseek(srcFd, dataStart, SEEK_HOLE)
            let endOff: off_t = dataEnd < 0 ? size : dataEnd

            try Self.copyRange(srcFd: srcFd, dstFd: dstFd, start: dataStart, end: endOff, buf: buf, bufSize: bufSize)
            pos = endOff
        }
    }

    private static func copyRange(
        srcFd: Int32,
        dstFd: Int32,
        start: off_t,
        end: off_t,
        buf: UnsafeMutableRawPointer,
        bufSize: Int
    ) throws {
        var off = start
        while off < end {
            let want = Int(min(off_t(bufSize), end - off))
            let nread = pread(srcFd, buf, want, off)
            if nread < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if nread == 0 {
                // Source shorter than fstat reported — shouldn't happen, but
                // bail rather than spin.
                return
            }
            var written = 0
            while written < nread {
                let nwrite = pwrite(dstFd, buf.advanced(by: written), nread - written, off + off_t(written))
                if nwrite < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += nwrite
            }
            off += off_t(nread)
        }
    }
    #endif
}

#if os(macOS)

extension Mount {
    private enum StorageAttachmentType {
        case diskImage
        case networkBlockDevice
    }

    private var storageAttachmentType: StorageAttachmentType {
        let nbdSchemes = ["nbd://", "nbds://", "nbd+unix://", "nbds+unix://"]
        if nbdSchemes.contains(where: { self.source.hasPrefix($0) }) {
            return .networkBlockDevice
        }
        return .diskImage
    }

    func configure(config: inout VZVirtualMachineConfiguration) throws {
        switch self.runtimeOptions {
        case .virtioblk(let options):
            let device: VZStorageDeviceAttachment
            switch self.storageAttachmentType {
            case .networkBlockDevice:
                device = try VZNetworkBlockDeviceStorageDeviceAttachment.mountToVZAttachment(mount: self, options: options)
            case .diskImage:
                device = try VZDiskImageStorageDeviceAttachment.mountToVZAttachment(mount: self, options: options)
            }
            let attachment = VZVirtioBlockDeviceConfiguration(attachment: device)
            config.storageDevices.append(attachment)
        case .virtiofs(_):
            // VirtioFS mounts are handled centrally via VZMultipleDirectoryShare in VZVirtualMachineInstance
            // No per-mount device configuration needed
            break
        case .shared, .any:
            break
        }
    }
}

extension VZDiskImageStorageDeviceAttachment {
    static func mountToVZAttachment(mount: Mount, options: [String]) throws -> VZDiskImageStorageDeviceAttachment {
        var synchronizationMode: VZDiskImageSynchronizationMode = .fsync
        var cachingMode: VZDiskImageCachingMode = .cached

        for option in options {
            let split = option.split(separator: "=")
            if split.count != 2 {
                continue
            }

            let key = String(split[0])
            let value = String(split[1])

            switch key {
            case "vzDiskImageCachingMode":
                switch value {
                case "automatic":
                    cachingMode = .automatic
                case "cached":
                    cachingMode = .cached
                case "uncached":
                    cachingMode = .uncached
                default:
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "unknown vzDiskImageCachingMode value for virtio block device: \(value)"
                    )
                }
            case "vzDiskImageSynchronizationMode":
                switch value {
                case "full":
                    synchronizationMode = .full
                case "fsync":
                    synchronizationMode = .fsync
                case "none":
                    synchronizationMode = .none
                default:
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "unknown vzDiskImageSynchronizationMode value for virtio block device: \(value)"
                    )
                }
            default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "unknown vmm option encountered: \(key)"
                )
            }
        }
        return try VZDiskImageStorageDeviceAttachment(
            url: URL(filePath: mount.source),
            readOnly: mount.readonly,
            cachingMode: cachingMode,
            synchronizationMode: synchronizationMode
        )
    }
}

extension VZNetworkBlockDeviceStorageDeviceAttachment {
    static func mountToVZAttachment(mount: Mount, options: [String]) throws -> VZNetworkBlockDeviceStorageDeviceAttachment {
        guard let url = URL(string: mount.source) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid NBD URL: \(mount.source)"
            )
        }

        var timeout: TimeInterval = 5
        var synchronizationMode: VZDiskSynchronizationMode = .full

        for option in options {
            let split = option.split(separator: "=")
            if split.count != 2 {
                continue
            }

            let key = String(split[0])
            let value = String(split[1])

            switch key {
            case "vzTimeout":
                guard let t = TimeInterval(value) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "invalid vzTimeout value for NBD device: \(value)"
                    )
                }
                timeout = t
            case "vzSynchronizationMode":
                switch value {
                case "full":
                    synchronizationMode = .full
                case "none":
                    synchronizationMode = .none
                default:
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "unknown vzSynchronizationMode value for NBD device: \(value)"
                    )
                }
            default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "unknown vmm option encountered: \(key)"
                )
            }
        }

        return try VZNetworkBlockDeviceStorageDeviceAttachment(
            url: url,
            timeout: timeout,
            isForcedReadOnly: mount.readonly,
            synchronizationMode: synchronizationMode
        )
    }
}

#endif

extension Mount {
    fileprivate var readonly: Bool {
        self.options.contains("ro")
    }

    /// Returns true if this mount is a virtio block device.
    public var isBlock: Bool {
        if case .virtioblk = self.runtimeOptions {
            return true
        }
        return false
    }
}
