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

#if os(macOS)
import ContainerizationError
import Foundation
import Testing
@preconcurrency import Virtualization

@testable import Containerization

struct VZVirtualMachineConfigurationSnapshotTests {
    /// A snapshot with one storage device and one network device, built the way production does.
    private func makeSnapshot() throws -> VZVirtualMachineConfigurationSnapshot {
        let (config, dir) = try makeConfiguration()
        defer { try? FileManager.default.removeItem(at: dir) }

        let disk = dir.appendingPathComponent("a.img")
        try Data(count: 4096).write(to: disk)
        let block = VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))
        config.storageDevices = [block]

        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [nic]
        return try VZVirtualMachineConfigurationSnapshot(configuration: config)
    }

    @Test func roundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try makeSnapshot()
        try snapshot.save(to: url)
        #expect(try VZVirtualMachineConfigurationSnapshot.load(from: url) == snapshot)
    }

    @Test func identicalSnapshotsHaveNoDifferences() throws {
        let base = try makeSnapshot()
        #expect(base.differences(from: base).isEmpty)
    }

    @Test func diskImagePathsAreNotCompared() throws {
        let base = try makeSnapshot()
        var current = base
        current.storage[0].path = "/cloned/a.img"
        #expect(base.differences(from: current).isEmpty)
    }

    @Test func kernelPathIsNotComparedButContentIs() throws {
        let base = try makeSnapshot()
        var moved = base
        moved.bootLoader.kernel.path = "/elsewhere/k"
        #expect(base.differences(from: moved).isEmpty)

        var changed = base
        changed.bootLoader.kernel.sha256 = "bb"
        let diffs = base.differences(from: changed)
        #expect(diffs.count == 1)
        #expect(diffs.first?.contains("kernel sha256") == true)
    }

    @Test func reportsEveryMismatch() throws {
        let base = try makeSnapshot()
        var current = base
        current.cpuCount = 4
        current.memorySize = 2 << 30
        current.platform.machineIdentifier = Data([9])
        current.network[0].macAddress = "02:00:00:00:00:02"
        current.network[0].attachment = .vmnet
        current.storage[0].readOnly = true
        current.serialPorts = [.init(attachment: .file)]

        let diffs = base.differences(from: current)
        for name in ["cpu count", "memory size", "machine identifier", "mac address", "attachment", "read-only", "serial ports"] {
            #expect(diffs.contains { $0.contains(name) }, "missing difference for \(name)")
        }
    }

    @Test func reportsStorageCountMismatch() throws {
        let base = try makeSnapshot()
        var current = base
        current.storage = []
        let diffs = base.differences(from: current)
        #expect(diffs.contains { $0.contains("storage device count") })
    }

    // MARK: Building from a VZ configuration

    private func makeConfiguration() throws -> (VZVirtualMachineConfiguration, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let kernel = dir.appendingPathComponent("vmlinux")
        try Data("kernel".utf8).write(to: kernel)

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 2
        config.memorySize = 1 << 30
        config.platform = VZGenericPlatformConfiguration()
        let loader = VZLinuxBootLoader(kernelURL: kernel)
        loader.commandLine = "console=hvc0"
        config.bootLoader = loader
        return (config, dir)
    }

    @Test func buildsFromMinimalConfiguration() throws {
        let (config, dir) = try makeConfiguration()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = try VZVirtualMachineConfigurationSnapshot(configuration: config)
        #expect(snapshot.cpuCount == 2)
        #expect(snapshot.memorySize == 1 << 30)
        #expect(snapshot.bootLoader.commandLine == "console=hvc0")
        #expect(snapshot.bootLoader.kernel.sha256.count == 64)
        #expect(snapshot.storage.isEmpty)
        #expect(snapshot.network.isEmpty)
        #expect(snapshot.platform.nestedVirtualization == false)

        // Building twice from the same configuration is deterministic.
        let again = try VZVirtualMachineConfigurationSnapshot(configuration: config)
        #expect(snapshot.differences(from: again).isEmpty)
    }

    @Test func kernelHashMatchesContent() throws {
        let (config, dir) = try makeConfiguration()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = try VZVirtualMachineConfigurationSnapshot(configuration: config)
        #expect(snapshot.bootLoader.kernel.sha256.count == 64)

        try Data("different".utf8).write(to: URL(fileURLWithPath: snapshot.bootLoader.kernel.path))
        let changed = try VZVirtualMachineConfigurationSnapshot(configuration: config)
        #expect(snapshot.differences(from: changed).contains { $0.contains("kernel sha256") })
    }

    @Test func rejectsUnsupportedDevices() throws {
        let (config, dir) = try makeConfiguration()
        defer { try? FileManager.default.removeItem(at: dir) }

        config.keyboards = [VZUSBKeyboardConfiguration()]
        do {
            _ = try VZVirtualMachineConfigurationSnapshot(configuration: config)
            Issue.record("expected an unsupported error")
        } catch let error as ContainerizationError {
            #expect(error.code == .unsupported)
        }
    }

    @Test func rejectsDirectorySharesWithContents() throws {
        let (config, dir) = try makeConfiguration()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "share")
        fs.share = VZMultipleDirectoryShare(directories: ["d": VZSharedDirectory(url: dir, readOnly: true)])
        config.directorySharingDevices = [fs]
        do {
            _ = try VZVirtualMachineConfigurationSnapshot(configuration: config)
            Issue.record("expected an unsupported error")
        } catch let error as ContainerizationError {
            #expect(error.code == .unsupported)
        }
    }

    @Test func acceptsEmptyDirectoryShare() throws {
        let (config, dir) = try makeConfiguration()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "share")
        fs.share = VZMultipleDirectoryShare(directories: [:])
        config.directorySharingDevices = [fs]
        let snapshot = try VZVirtualMachineConfigurationSnapshot(configuration: config)
        #expect(snapshot.directorySharing == [.init(tag: "share")])
    }
}
#endif
