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

#if os(Linux)
import CloudHypervisor
import Foundation
import Synchronization
import Testing

@testable import Containerization

/// The boot disks in the cloud-hypervisor VM config get `direct` only when the VM
/// asks for direct disk I/O.
/// An extension records the config in `configureCH` and then fails the start, so
/// cloud-hypervisor never runs.
struct CHDirectDiskIOTests {
    private struct Captured: Error {}

    private final class CaptureConfig: CHInstanceExtension {
        let config = Mutex<CloudHypervisor.VmConfig?>(nil)

        func configureCH(_ config: inout CloudHypervisor.VmConfig) throws {
            let value = config
            self.config.withLock { $0 = value }
            throw Captured()
        }
    }

    private func bootDisks(directDiskIO: Bool) async throws -> [CloudHypervisor.DiskConfig] {
        let runtimeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ch-direct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let capture = CaptureConfig()
        let instance = try CHVirtualMachineInstance(
            runtimeRoot: runtimeRoot,
            chBinary: URL(fileURLWithPath: "/bin/false"),
            virtiofsdBinary: nil
        ) { config in
            config.kernel = Kernel(path: URL(fileURLWithPath: "/dev/null"), platform: .linuxArm)
            config.initialFilesystem = .block(format: "ext4", source: "/tmp/rootfs.ext4", destination: "/")
            config.mountsByID = ["c1": [.block(format: "ext4", source: "/tmp/c1.ext4", destination: "/")]]
            config.extensions = [capture]
            config.directDiskIO = directDiskIO
        }
        await #expect(throws: Captured.self) {
            try await instance.start()
        }
        return try #require(capture.config.withLock { $0 }?.disks)
    }

    @Test func directDiskIOSetsDirectOnEveryBootDisk() async throws {
        let disks = try await bootDisks(directDiskIO: true)
        #expect(disks.count == 2)
        #expect(disks.allSatisfy { $0.direct == true })
    }

    @Test func defaultLeavesDirectUnset() async throws {
        let disks = try await bootDisks(directDiskIO: false)
        #expect(disks.count == 2)
        #expect(disks.allSatisfy { $0.direct == nil })
    }
}
#endif
