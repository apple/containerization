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
        case any
    }

    init(
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
        options: [String] = []
    ) -> Self {
        .init(
            type: type,
            source: source,
            destination: destination,
            options: options,
            runtimeOptions: .any
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
    var isFile: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: self.source, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    var parentDirectory: String {
        URL(fileURLWithPath: self.source).deletingLastPathComponent().path
    }

    var filename: String {
        URL(fileURLWithPath: self.source).lastPathComponent
    }

    /// Create an isolated temporary directory containing only the target file via hardlink
    func createIsolatedFileShare() throws -> String {
        // Create deterministic temp directory
        let combinedPath = "\(self.source)|\(self.destination)"
        let sourceHash = try hashMountSource(source: combinedPath)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("containerization-file-mount-\(sourceHash)")

        // Use destination filename for the hardlink instead of source filename
        let destinationFilename = URL(fileURLWithPath: self.destination).lastPathComponent
        let isolatedFile = tempDir.appendingPathComponent(destinationFilename)

        // Check if hard link already exists
        if FileManager.default.fileExists(atPath: isolatedFile.path) {
            // Hard link already exists - nothing to do
            return tempDir.path
        }

        // Validate source file exists and is a regular file
        try validateSourceFile()

        // Atomically create directory
        try createDirectory(at: tempDir)

        let sourceFile = URL(fileURLWithPath: self.source)

        // Create the hard link, handling race conditions
        do {
            try FileManager.default.linkItem(at: sourceFile, to: isolatedFile)
        } catch CocoaError.fileWriteFileExists {
            // Another thread created the hardlink - that's fine
        } catch {
            throw ContainerizationError(.internalError, message: "Failed to create hardlink: \(error.localizedDescription)")
        }

        // Final verification that the hardlinked file exists
        guard FileManager.default.fileExists(atPath: isolatedFile.path) else {
            throw ContainerizationError(.notFound, message: "Failed to create hardlink at: \(isolatedFile.path)")
        }

        return tempDir.path
    }

    /// Release reference to an isolated file share directory
    /// No-op to avoid race conditions in parallel test execution
    static func releaseIsolatedFileShare(source: String, destination: String) {
        // No cleanup during tests to avoid race conditions
        // OS will clean up temp directories on reboot
    }

    /// Validate that the source file exists, is readable, and is not a symlink
    private func validateSourceFile() throws {

        // Check if file exists
        guard FileManager.default.fileExists(atPath: self.source) else {
            throw ContainerizationError(.notFound, message: "Source file does not exist: \(self.source)")
        }

        // Get file attributes to check if it's a regular file
        let attributes = try FileManager.default.attributesOfItem(atPath: self.source)
        let fileType = attributes[.type] as? FileAttributeType

        // Reject symlinks to prevent following links to unintended targets
        guard fileType != .typeSymbolicLink else {
            throw ContainerizationError(.invalidArgument, message: "Cannot mount symlink: \(self.source)")
        }

        // Ensure it's a regular file
        guard fileType == .typeRegular else {
            throw ContainerizationError(.invalidArgument, message: "Source must be a regular file: \(self.source)")
        }

        // Check if file is readable
        guard FileManager.default.isReadableFile(atPath: self.source) else {
            throw ContainerizationError(.invalidArgument, message: "Source file is not readable: \(self.source)")
        }
    }

    /// Atomically create directory (to prevent TOCTOU race conditions)
    private func createDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Register for cleanup
            if url.path.contains("containerization-file-mount-") {
                VZVirtualMachineInstance.registerTempDirectory(url.path)
            }
        } catch CocoaError.fileWriteFileExists {
            // Directory already exists, verify it's actually a directory
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw ContainerizationError(.invalidArgument, message: "Path exists but is not a directory: \(url.path)")
            }
            // Directory exists and is valid, continue
        } catch {
            throw ContainerizationError(.internalError, message: "Failed to create directory \(url.path): \(error.localizedDescription)")
        }
    }

    func configure(config: inout VZVirtualMachineConfiguration) throws {
        switch self.runtimeOptions {
        case .virtioblk(let options):
            let device = try VZDiskImageStorageDeviceAttachment.mountToVZAttachment(mount: self, options: options)
            let attachment = VZVirtioBlockDeviceConfiguration(attachment: device)
            config.storageDevices.append(attachment)
        case .virtiofs(_):
            guard FileManager.default.fileExists(atPath: self.source) else {
                throw ContainerizationError(.notFound, message: "path \(source) does not exist")
            }

            let shareSource: String
            if isFile {
                shareSource = try createIsolatedFileShare()
            } else {
                shareSource = self.source
            }

            let name = try hashMountSource(source: shareSource)
            let urlSource = URL(fileURLWithPath: shareSource)

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
        var synchronizationMode: VZDiskImageSynchronizationMode = .none

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
