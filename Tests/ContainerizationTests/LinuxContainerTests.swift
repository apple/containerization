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

import ContainerizationOCI
import Foundation
import Testing

@testable import Containerization

struct LinuxContainerTests {

    @Test func processInitFromImageConfigWithAllFields() {
        let imageConfig = ImageConfig(
            user: "appuser",
            env: ["NODE_ENV=production", "PORT=3000"],
            entrypoint: ["/usr/bin/node"],
            cmd: ["app.js", "--verbose"],
            workingDir: "/app"
        )

        let process = LinuxProcessConfiguration(from: imageConfig)

        #expect(process.workingDirectory == "/app")
        #expect(process.environmentVariables == ["NODE_ENV=production", "PORT=3000"])
        #expect(process.arguments == ["/usr/bin/node", "app.js", "--verbose"])
        #expect(process.user.username == "appuser")
    }

    @Test func processInitFromImageConfigWithNilValues() {
        let imageConfig = ImageConfig(
            user: nil,
            env: nil,
            entrypoint: nil,
            cmd: nil,
            workingDir: nil
        )

        let process = LinuxProcessConfiguration(from: imageConfig)

        #expect(process.workingDirectory == "/")
        #expect(process.environmentVariables == [])
        #expect(process.arguments == [])
        #expect(process.user.username == "")  // Default User() has empty string username
    }

    @Test func processInitFromImageConfigEntrypointAndCmdConcatenation() {
        let imageConfig = ImageConfig(
            entrypoint: ["/bin/sh", "-c"],
            cmd: ["echo 'hello'", "&&", "sleep 10"]
        )

        let process = LinuxProcessConfiguration(from: imageConfig)

        #expect(process.arguments == ["/bin/sh", "-c", "echo 'hello'", "&&", "sleep 10"])
    }

    @Test func runtimeSpecIncludesConfiguredBlockIO() throws {
        let blockIO = LinuxBlockIO(
            weight: 500,
            leafWeight: 300,
            weightDevice: [
                LinuxWeightDevice(major: 8, minor: 0, weight: 700, leafWeight: 400)
            ],
            throttleReadBpsDevice: [
                LinuxThrottleDevice(major: 8, minor: 16, rate: 1_048_576)
            ],
            throttleWriteBpsDevice: [
                LinuxThrottleDevice(major: 8, minor: 32, rate: 2_097_152)
            ],
            throttleReadIOPSDevice: [
                LinuxThrottleDevice(major: 8, minor: 48, rate: 1_000)
            ],
            throttleWriteIOPSDevice: [
                LinuxThrottleDevice(major: 8, minor: 64, rate: 2_000)
            ]
        )

        let container = try LinuxContainer(
            "blkio-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: StubVirtualMachineManager(),
            configuration: .init(process: .init(), blockIO: blockIO)
        )

        let resources = try #require(container.generateRuntimeSpec().linux?.resources)
        let specBlockIO = try #require(resources.blockIO)

        #expect(specBlockIO.weight == 500)
        #expect(specBlockIO.leafWeight == 300)
        #expect(specBlockIO.weightDevice.first?.major == 8)
        #expect(specBlockIO.weightDevice.first?.minor == 0)
        #expect(specBlockIO.weightDevice.first?.weight == 700)
        #expect(specBlockIO.weightDevice.first?.leafWeight == 400)
        #expect(specBlockIO.throttleReadBpsDevice.first?.rate == 1_048_576)
        #expect(specBlockIO.throttleWriteBpsDevice.first?.rate == 2_097_152)
        #expect(specBlockIO.throttleReadIOPSDevice.first?.rate == 1_000)
        #expect(specBlockIO.throttleWriteIOPSDevice.first?.rate == 2_000)
    }
}

private struct StubVirtualMachineManager: VirtualMachineManager {
    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        fatalError("StubVirtualMachineManager.create should not be called by LinuxContainerTests")
    }
}
