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
import ContainerizationError
import CryptoKit
import Foundation
@preconcurrency import Virtualization

/// A persistable description of a virtual machine's board: its platform and
/// peripherals. It does not describe in-memory state (RAM, registers, device
/// internals); that lives in the file written by `saveMachineStateTo`.
///
/// The snapshot is built by walking a final, validated
/// `VZVirtualMachineConfiguration`, so it covers everything `toVZ()` and any
/// `VZInstanceExtension` produced. It is a description, not a recipe:
/// `VZVirtualMachineConfiguration` is always built by `toVZ()`, and the
/// snapshot is only used to verify that a newly built configuration matches
/// the one a saved machine state depends on, and to tell the caller which
/// backing state (disk images, network identity) it must preserve.
///
/// Building a snapshot is also the sanitizing step: any device or attachment
/// outside the allowlist in `docs/vm-save-restore.md` throws
/// `ContainerizationError(.unsupported)`.
public struct VZVirtualMachineConfigurationSnapshot: Codable, Sendable, Equatable {
    /// The current manifest format version.
    public static let currentVersion = 1

    /// A file that is identified by content, because its bits live in the
    /// guest's memory state and the path alone does not identify them.
    public struct HashedFile: Codable, Sendable, Equatable {
        public var path: String
        public var sha256: String
    }

    public struct Host: Codable, Sendable, Equatable {
        /// `ProcessInfo.operatingSystemVersionString`.
        public var osVersion: String
        /// The `hw.model` sysctl value.
        public var model: String
    }

    public struct Platform: Codable, Sendable, Equatable {
        /// `VZGenericMachineIdentifier.dataRepresentation`. VZ generates a new
        /// identifier per configuration unless one is set, so it must be
        /// persisted and reapplied.
        public var machineIdentifier: Data
        public var nestedVirtualization: Bool
    }

    public struct BootLoader: Codable, Sendable, Equatable {
        public var kernel: HashedFile
        public var commandLine: String
        /// Set when the configuration carries a separate initial ramdisk.
        public var initialRamdisk: HashedFile?
    }

    public enum CachingMode: String, Codable, Sendable {
        case automatic
        case cached
        case uncached
    }

    public enum SynchronizationMode: String, Codable, Sendable {
        case full
        case fsync
        case none
    }

    /// A virtio block device backed by a disk image.
    ///
    /// The image is its own source of truth, so it is not hashed. The caller is
    /// responsible for preserving its contents and presenting it again.
    /// `sha256` is only set for the initial filesystem, whose contents the
    /// guest has already loaded into memory.
    public struct Storage: Codable, Sendable, Equatable {
        public var path: String
        public var sizeInBytes: UInt64
        public var readOnly: Bool
        public var cachingMode: CachingMode
        public var synchronizationMode: SynchronizationMode
        public var sha256: String?
    }

    public enum NetworkAttachment: String, Codable, Sendable {
        case nat
        /// A vmnet network. The host side (subnet, gateway) is owned by the caller and must be
        /// recreated before a restore.
        case vmnet
    }

    /// A virtio network device. `macAddress` is always the effective address,
    /// including one VZ generated because none was requested.
    public struct Network: Codable, Sendable, Equatable {
        public var macAddress: String
        public var attachment: NetworkAttachment
    }

    /// A virtio-fs device. Only an empty `VZMultipleDirectoryShare` is allowed.
    public struct DirectorySharing: Codable, Sendable, Equatable {
        public var tag: String
    }

    public enum SerialAttachment: String, Codable, Sendable {
        case file
        case fileHandle
    }

    public struct SerialPort: Codable, Sendable, Equatable {
        public var attachment: SerialAttachment
    }

    public var version: Int
    public var host: Host
    public var cpuCount: Int
    public var memorySize: UInt64
    public var platform: Platform
    public var bootLoader: BootLoader
    public var storage: [Storage]
    public var network: [Network]
    public var directorySharing: [DirectorySharing]
    public var socketDeviceCount: Int
    public var entropyDeviceCount: Int
    public var serialPorts: [SerialPort]

    /// Build a snapshot from a validated VZ configuration.
    ///
    /// - Parameters:
    ///   - configuration: The configuration the machine is (or will be) built from.
    ///   - initialFilesystem: The initial filesystem image. It is attached as a
    ///     block device but is identified by content like the kernel.
    /// - Throws: `ContainerizationError(.unsupported)` for anything that is not
    ///   explicitly allowed.
    public init(configuration: VZVirtualMachineConfiguration, initialFilesystem: URL? = nil) throws {
        self.version = Self.currentVersion
        self.host = Host(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            model: Self.sysctlString("hw.model") ?? "unknown"
        )
        self.cpuCount = configuration.cpuCount
        self.memorySize = configuration.memorySize

        guard let platform = configuration.platform as? VZGenericPlatformConfiguration else {
            throw Self.unsupported("platform \(type(of: configuration.platform))")
        }
        self.platform = Platform(
            machineIdentifier: platform.machineIdentifier.dataRepresentation,
            nestedVirtualization: platform.isNestedVirtualizationEnabled
        )
        // Nested virtualization state is not supported in v1.
        if platform.isNestedVirtualizationEnabled {
            throw Self.unsupported("nested virtualization")
        }

        guard let loader = configuration.bootLoader as? VZLinuxBootLoader else {
            throw Self.unsupported("boot loader \(configuration.bootLoader.map { "\(type(of: $0))" } ?? "nil")")
        }
        self.bootLoader = BootLoader(
            kernel: try Self.hashedFile(loader.kernelURL),
            commandLine: loader.commandLine,
            initialRamdisk: try loader.initialRamdiskURL.map { try Self.hashedFile($0) }
        )

        self.storage = try configuration.storageDevices.map { device in
            guard
                let block = device as? VZVirtioBlockDeviceConfiguration,
                let attachment = device.attachment as? VZDiskImageStorageDeviceAttachment
            else {
                throw Self.unsupported("storage device \(type(of: device)) with attachment \(type(of: device.attachment))")
            }
            // The identifier is guest-visible (virtio-blk serial, /dev/disk/by-id) and is not
            // recorded, so only the default (empty) value is allowed.
            guard block.blockDeviceIdentifier.isEmpty else {
                throw Self.unsupported("storage device with block device identifier '\(block.blockDeviceIdentifier)'")
            }
            return try Self.storage(attachment, initialFilesystem: initialFilesystem)
        }

        self.network = try configuration.networkDevices.map { device in
            guard let device = device as? VZVirtioNetworkDeviceConfiguration else {
                throw Self.unsupported("network device \(type(of: device))")
            }
            let attachment: NetworkAttachment
            if device.attachment is VZNATNetworkDeviceAttachment {
                attachment = .nat
            } else if #available(macOS 26, *), device.attachment is VZVmnetNetworkDeviceAttachment {
                attachment = .vmnet
            } else {
                throw Self.unsupported("network attachment \(device.attachment.map { "\(type(of: $0))" } ?? "nil")")
            }
            return Network(macAddress: device.macAddress.string, attachment: attachment)
        }

        self.directorySharing = try configuration.directorySharingDevices.map { device in
            guard
                let device = device as? VZVirtioFileSystemDeviceConfiguration,
                let share = device.share as? VZMultipleDirectoryShare
            else {
                throw Self.unsupported("directory sharing device \(type(of: device))")
            }
            // Host files cannot be snapshotted, so no share may be present.
            guard share.directories.isEmpty else {
                throw Self.unsupported("virtiofs device '\(device.tag)' with \(share.directories.count) share(s)")
            }
            return DirectorySharing(tag: device.tag)
        }

        guard configuration.socketDevices.allSatisfy({ $0 is VZVirtioSocketDeviceConfiguration }) else {
            throw Self.unsupported("socket device")
        }
        self.socketDeviceCount = configuration.socketDevices.count

        guard configuration.entropyDevices.allSatisfy({ $0 is VZVirtioEntropyDeviceConfiguration }) else {
            throw Self.unsupported("entropy device")
        }
        self.entropyDeviceCount = configuration.entropyDevices.count

        self.serialPorts = try configuration.serialPorts.map { port in
            guard port is VZVirtioConsoleDeviceSerialPortConfiguration else {
                throw Self.unsupported("serial port \(type(of: port))")
            }
            switch port.attachment {
            case is VZFileSerialPortAttachment:
                return SerialPort(attachment: .file)
            case is VZFileHandleSerialPortAttachment:
                return SerialPort(attachment: .fileHandle)
            default:
                throw Self.unsupported("serial attachment \(port.attachment.map { "\(type(of: $0))" } ?? "nil")")
            }
        }

        // Default-deny: every remaining device category must be empty.
        let denied: [(String, Int)] = [
            ("console devices", configuration.consoleDevices.count),
            ("memory balloon devices", configuration.memoryBalloonDevices.count),
            ("graphics devices", configuration.graphicsDevices.count),
            ("keyboards", configuration.keyboards.count),
            ("pointing devices", configuration.pointingDevices.count),
            ("audio devices", configuration.audioDevices.count),
            ("USB controllers", configuration.usbControllers.count),
        ]
        for (name, count) in denied where count > 0 {
            throw Self.unsupported("\(count) \(name)")
        }
    }

    /// Read a snapshot written by ``save(to:)``.
    ///
    /// Use this before creating the instance that will restore a saved state, e.g. to learn the
    /// `platform.machineIdentifier` it must be created with.
    ///
    /// - Parameter url: The snapshot file.
    public static func load(from url: URL) throws -> VZVirtualMachineConfigurationSnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VZVirtualMachineConfigurationSnapshot.self, from: data)
    }

    /// Write the snapshot to the file at `url` as JSON.
    ///
    /// - Parameter url: The snapshot file.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }

    /// Describe every way `current` differs from this (saved) snapshot in a way
    /// that makes restoring this snapshot's machine state unsafe.
    ///
    /// File paths are not compared where content is identified by hash, and
    /// disk image paths are never compared: a caller restoring from a cloned
    /// image legitimately presents a different path. An empty result means the
    /// two boards match.
    public func differences(from current: VZVirtualMachineConfigurationSnapshot) -> [String] {
        var out: [String] = []
        func check<T: Equatable>(_ name: String, _ saved: T, _ now: T) {
            if saved != now { out.append("\(name): saved \(saved), current \(now)") }
        }

        check("snapshot version", version, current.version)
        check("host os version", host.osVersion, current.host.osVersion)
        check("host model", host.model, current.host.model)
        check("cpu count", cpuCount, current.cpuCount)
        check("memory size", memorySize, current.memorySize)
        check("machine identifier", platform.machineIdentifier, current.platform.machineIdentifier)
        check("nested virtualization", platform.nestedVirtualization, current.platform.nestedVirtualization)
        check("kernel sha256", bootLoader.kernel.sha256, current.bootLoader.kernel.sha256)
        check("kernel command line", bootLoader.commandLine, current.bootLoader.commandLine)
        check("initial ramdisk sha256", bootLoader.initialRamdisk?.sha256, current.bootLoader.initialRamdisk?.sha256)

        check("storage device count", storage.count, current.storage.count)
        for (index, (saved, now)) in zip(storage, current.storage).enumerated() {
            check("storage[\(index)] size", saved.sizeInBytes, now.sizeInBytes)
            check("storage[\(index)] read-only", saved.readOnly, now.readOnly)
            check("storage[\(index)] caching mode", saved.cachingMode, now.cachingMode)
            check("storage[\(index)] synchronization mode", saved.synchronizationMode, now.synchronizationMode)
            check("storage[\(index)] sha256", saved.sha256, now.sha256)
        }

        check("network device count", network.count, current.network.count)
        for (index, (saved, now)) in zip(network, current.network).enumerated() {
            check("network[\(index)] mac address", saved.macAddress, now.macAddress)
            check("network[\(index)] attachment", saved.attachment, now.attachment)
        }

        check("directory sharing devices", directorySharing, current.directorySharing)
        check("socket device count", socketDeviceCount, current.socketDeviceCount)
        check("entropy device count", entropyDeviceCount, current.entropyDeviceCount)
        check("serial ports", serialPorts, current.serialPorts)
        return out
    }
}

extension VZVirtualMachineConfigurationSnapshot {
    private static func unsupported(_ what: String) -> ContainerizationError {
        ContainerizationError(.unsupported, message: "\(what) is not supported for save/restore")
    }

    private static func storage(
        _ attachment: VZDiskImageStorageDeviceAttachment,
        initialFilesystem: URL?
    ) throws -> Storage {
        let url = attachment.url
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0

        let caching: CachingMode
        switch attachment.cachingMode {
        case .automatic: caching = .automatic
        case .cached: caching = .cached
        case .uncached: caching = .uncached
        @unknown default: throw unsupported("disk caching mode \(attachment.cachingMode)")
        }

        let sync: SynchronizationMode
        switch attachment.synchronizationMode {
        case .full: sync = .full
        case .fsync: sync = .fsync
        case .none: sync = .none
        @unknown default: throw unsupported("disk synchronization mode \(attachment.synchronizationMode)")
        }

        let isInitialFilesystem = initialFilesystem.map { $0.standardizedFileURL == url.standardizedFileURL } ?? false
        return Storage(
            path: url.path,
            sizeInBytes: size,
            readOnly: attachment.isReadOnly,
            cachingMode: caching,
            synchronizationMode: sync,
            sha256: isInitialFilesystem ? try sha256(of: url) : nil
        )
    }

    private static func hashedFile(_ url: URL) throws -> HashedFile {
        HashedFile(path: url.path, sha256: try sha256(of: url))
    }

    /// Hex SHA-256 of a file, read in chunks so large kernels and images are not loaded whole.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
