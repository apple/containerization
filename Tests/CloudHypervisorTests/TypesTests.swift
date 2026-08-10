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

import Foundation
import Testing

@testable import CloudHypervisor

@Suite("CloudHypervisor types")
struct TypesTests {
    @Test("VmConfig round-trips through JSON")
    func vmConfigRoundTrip() throws {
        let cfg = CloudHypervisor.VmConfig(
            cpus: CloudHypervisor.CpusConfig(bootVcpus: 2, maxVcpus: 2),
            memory: CloudHypervisor.MemoryConfig(size: UInt64(1) << 30),
            payload: CloudHypervisor.PayloadConfig(
                kernel: "/path/to/vmlinux",
                cmdline: "init=/sbin/vminitd ro"
            ),
            disks: nil,
            net: nil,
            fs: nil,
            vsock: nil,
            console: CloudHypervisor.ConsoleConfig(mode: .Null),
            serial: CloudHypervisor.ConsoleConfig(mode: .Null)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cfg)
        let decoded = try JSONDecoder().decode(CloudHypervisor.VmConfig.self, from: data)
        #expect(decoded == cfg)

        // Verify snake_case keys are emitted.
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString.contains("\"boot_vcpus\""))
        #expect(jsonString.contains("\"max_vcpus\""))
    }

    @Test("CpusConfig round-trips through JSON")
    func cpusConfigRoundTrip() throws {
        let cfg = CloudHypervisor.CpusConfig(bootVcpus: 4, maxVcpus: 8)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(CloudHypervisor.CpusConfig.self, from: data)
        #expect(decoded == cfg)
    }

    @Test("MemoryConfig round-trips through JSON")
    func memoryConfigRoundTrip() throws {
        let cfg = CloudHypervisor.MemoryConfig(size: UInt64(2) << 30, hotplugSize: UInt64(1) << 30, mergeable: true)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(CloudHypervisor.MemoryConfig.self, from: data)
        #expect(decoded == cfg)
    }

    @Test("MemoryConfig omits nil optional fields from JSON")
    func memoryConfigNilOmission() throws {
        let cfg = CloudHypervisor.MemoryConfig(size: UInt64(1) << 30)
        let data = try JSONEncoder().encode(cfg)
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(!jsonString.contains("\"hotplug_size\""))
        #expect(!jsonString.contains("\"mergeable\""))
    }

    @Test("PayloadConfig round-trips through JSON")
    func payloadConfigRoundTrip() throws {
        let cfg = CloudHypervisor.PayloadConfig(
            kernel: "/boot/vmlinux",
            initramfs: "/boot/initrd",
            cmdline: "console=ttyS0"
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(CloudHypervisor.PayloadConfig.self, from: data)
        #expect(decoded == cfg)
    }

    @Test("ConsoleConfig round-trips through JSON with capitalized mode strings")
    func consoleConfigRoundTrip() throws {
        for mode in [
            CloudHypervisor.ConsoleConfig.Mode.Off,
            .Pty,
            .Tty,
            .File,
            .Socket,
            .Null,
        ] {
            let cfg = CloudHypervisor.ConsoleConfig(mode: mode)
            let data = try JSONEncoder().encode(cfg)
            let decoded = try JSONDecoder().decode(CloudHypervisor.ConsoleConfig.self, from: data)
            #expect(decoded == cfg)
            // CH uses capitalized strings: "Off", "Pty", etc.
            let jsonString = try #require(String(data: data, encoding: .utf8))
            #expect(jsonString.contains("\"" + mode.rawValue + "\""))
        }
    }

    @Test("DiskConfig round-trips through JSON")
    func diskConfigRoundTrip() throws {
        let cfg = CloudHypervisor.DiskConfig(
            path: "/var/lib/disk.raw",
            readonly: true,
            direct: false,
            iommu: nil,
            id: "disk0",
            pciSegment: 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cfg)
        let decoded = try JSONDecoder().decode(CloudHypervisor.DiskConfig.self, from: data)
        #expect(decoded == cfg)

        // Verify snake_case key for pci_segment.
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString.contains("\"pci_segment\""))
    }

    @Test("DiskConfig omits nil optional fields from JSON")
    func diskConfigNilOmission() throws {
        let cfg = CloudHypervisor.DiskConfig(path: "/var/lib/disk.raw")
        let data = try JSONEncoder().encode(cfg)
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(!jsonString.contains("\"readonly\""))
        #expect(!jsonString.contains("\"direct\""))
        #expect(!jsonString.contains("\"iommu\""))
        #expect(!jsonString.contains("\"id\""))
        #expect(!jsonString.contains("\"pci_segment\""))
    }

    @Test("NetConfig round-trips through JSON")
    func netConfigRoundTrip() throws {
        let cfg = CloudHypervisor.NetConfig(
            tap: "tap0",
            ip: "192.168.0.1",
            mask: "255.255.255.0",
            mac: "AA:BB:CC:DD:EE:FF",
            mtu: 1500,
            numQueues: 2,
            queueSize: 256,
            id: "net0"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cfg)
        let decoded = try JSONDecoder().decode(CloudHypervisor.NetConfig.self, from: data)
        #expect(decoded == cfg)

        // Verify snake_case keys.
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString.contains("\"num_queues\""))
        #expect(jsonString.contains("\"queue_size\""))
    }

    @Test("FsConfig round-trips through JSON")
    func fsConfigRoundTrip() throws {
        let cfg = CloudHypervisor.FsConfig(
            tag: "virtiofs0",
            socket: "/run/virtiofs.sock",
            numQueues: 1,
            queueSize: 1024,
            id: "fs0",
            pciSegment: nil
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(CloudHypervisor.FsConfig.self, from: data)
        #expect(decoded == cfg)
    }

    @Test("VsockConfig round-trips through JSON")
    func vsockConfigRoundTrip() throws {
        let cfg = CloudHypervisor.VsockConfig(
            cid: 3,
            socket: "/run/vsock.sock",
            iommu: false,
            id: "vsock0"
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(CloudHypervisor.VsockConfig.self, from: data)
        #expect(decoded == cfg)
    }

    @Test("PciDeviceInfo round-trips through JSON")
    func pciDeviceInfoRoundTrip() throws {
        let info = CloudHypervisor.PciDeviceInfo(id: "disk0", bdf: "0000:00:03.0")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(CloudHypervisor.PciDeviceInfo.self, from: data)
        #expect(decoded == info)
    }

    // MARK: - VmInfo / VmState

    @Test("VmState round-trips through JSON with CH literal strings")
    func vmStateRoundTrip() throws {
        for state in [
            CloudHypervisor.VmState.Created,
            .Running,
            .Shutdown,
            .Paused,
            .BreakPoint,
        ] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(CloudHypervisor.VmState.self, from: data)
            #expect(decoded == state)
            // CH uses the capitalized raw string literals exactly.
            let jsonString = try #require(String(data: data, encoding: .utf8))
            #expect(jsonString.contains("\"" + state.rawValue + "\""))
        }
    }

    @Test("VmInfo round-trips through JSON")
    func vmInfoRoundTrip() throws {
        let cfg = CloudHypervisor.VmConfig(
            cpus: CloudHypervisor.CpusConfig(bootVcpus: 2, maxVcpus: 2),
            memory: CloudHypervisor.MemoryConfig(size: UInt64(1) << 30),
            payload: CloudHypervisor.PayloadConfig(kernel: "/boot/vmlinux"),
            console: CloudHypervisor.ConsoleConfig(mode: .Null),
            serial: CloudHypervisor.ConsoleConfig(mode: .Null)
        )
        let info = CloudHypervisor.VmInfo(
            config: cfg,
            state: .Running,
            memoryActualSize: 1_073_741_824
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(info)
        let decoded = try JSONDecoder().decode(CloudHypervisor.VmInfo.self, from: data)
        #expect(decoded == info)

        // Verify snake_case key is emitted.
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString.contains("\"memory_actual_size\""))
    }

    @Test("VmInfo omits nil optional fields from JSON")
    func vmInfoNilOmission() throws {
        let cfg = CloudHypervisor.VmConfig(
            cpus: CloudHypervisor.CpusConfig(bootVcpus: 1, maxVcpus: 1),
            memory: CloudHypervisor.MemoryConfig(size: UInt64(512) << 20),
            payload: CloudHypervisor.PayloadConfig(kernel: "/boot/vmlinux"),
            console: CloudHypervisor.ConsoleConfig(mode: .Off),
            serial: CloudHypervisor.ConsoleConfig(mode: .Off)
        )
        let info = CloudHypervisor.VmInfo(config: cfg, state: .Created)
        let data = try JSONEncoder().encode(info)
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(!jsonString.contains("\"memory_actual_size\""))
    }

    // MARK: - VmmPingResponse

    @Test("VmmPingResponse round-trips through JSON")
    func vmmPingResponseRoundTrip() throws {
        let ping = CloudHypervisor.VmmPingResponse(
            version: "v40.0",
            pid: 12345,
            features: ["acpi", "kvm"],
            buildVersion: "abc123"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ping)
        let decoded = try JSONDecoder().decode(CloudHypervisor.VmmPingResponse.self, from: data)
        #expect(decoded == ping)

        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString.contains("\"build_version\""))
    }

    @Test("VmmPingResponse omits nil optional fields from JSON")
    func vmmPingResponseNilOmission() throws {
        let ping = CloudHypervisor.VmmPingResponse(version: "v40.0")
        let data = try JSONEncoder().encode(ping)
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(!jsonString.contains("\"pid\""))
        #expect(!jsonString.contains("\"features\""))
        #expect(!jsonString.contains("\"build_version\""))
    }

    // MARK: - VmmInfo

    @Test("VmmInfo round-trips through JSON")
    func vmmInfoRoundTrip() throws {
        let cfg = CloudHypervisor.VmConfig(
            cpus: CloudHypervisor.CpusConfig(bootVcpus: 2, maxVcpus: 2),
            memory: CloudHypervisor.MemoryConfig(size: UInt64(1) << 30),
            payload: CloudHypervisor.PayloadConfig(kernel: "/boot/vmlinux"),
            console: CloudHypervisor.ConsoleConfig(mode: .Null),
            serial: CloudHypervisor.ConsoleConfig(mode: .Null)
        )
        let vmmInfo = CloudHypervisor.VmmInfo(
            version: "v40.0",
            pid: 99,
            buildVersion: "deadbeef",
            config: cfg
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(vmmInfo)
        let decoded = try JSONDecoder().decode(CloudHypervisor.VmmInfo.self, from: data)
        #expect(decoded == vmmInfo)

        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString.contains("\"build_version\""))
    }

    @Test("VmmInfo omits nil optional fields from JSON")
    func vmmInfoNilOmission() throws {
        let vmmInfo = CloudHypervisor.VmmInfo(version: "v40.0")
        let data = try JSONEncoder().encode(vmmInfo)
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(!jsonString.contains("\"pid\""))
        #expect(!jsonString.contains("\"build_version\""))
        #expect(!jsonString.contains("\"config\""))
    }
}
