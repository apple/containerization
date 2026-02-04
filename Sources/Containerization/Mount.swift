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

#if os(macOS)
import Foundation
import Virtualization
import ContainerizationError
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

    #if os(macOS)
    /// Clone the Mount to the provided path.
    ///
    /// This uses `clonefile` to provide a copy-on-write copy of the Mount.
    public func clone(to: String) throws -> Self {
        let fm = FileManager.default
        let src = self.source
        try fm.copyItem(atPath: src, toPath: to)

        return .init(
            type: self.type,
            source: to,
            destination: self.destination,
            options: self.options,
            runtimeOptions: self.runtimeOptions
        )
    }
    #endif
}

#if os(macOS)

extension Mount {
    func configure(config: inout VZVirtualMachineConfiguration) throws {
        switch self.runtimeOptions {
        case .virtioblk(let options):
            let device = try VZDiskImageStorageDeviceAttachment.mountToVZAttachment(mount: self, options: options)
            let attachment = VZVirtioBlockDeviceConfiguration(attachment: device)
            config.storageDevices.append(attachment)
        case .virtiofs(_):
            guard FileManager.default.fileExists(atPath: self.source) else {
                throw ContainerizationError(.notFound, message: "directory \(source) does not exist")
            }

            let name = try hashMountSource(source: self.source)
            let urlSource = URL(fileURLWithPath: source)

            let device = VZVirtioFileSystemDeviceConfiguration(tag: name)
            device.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(
                    url: urlSource,
                    readOnly: readonly
                )
            )
            config.directorySharingDevices.append(device)
        case .any:
            break
        }
    }
}

extension VZDiskImageStorageDeviceAttachment {
    static func mountToVZAttachment(mount: Mount, options: [String]) throws -> VZDiskImageStorageDeviceAttachment {
        var cachingMode: VZDiskImageCachingMode = .automatic
        var synchronizationMode: VZDiskImageSynchronizationMode = .fsync

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

#endif

extension Mount {
    fileprivate var readonly: Bool {
        self.options.contains("ro")
    }
}
