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
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Synchronization
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

    @Test func defaultCapabilitiesAreRestrictedOCISet() {
        // Regression guard against shipping `.allCapabilities` as the default.
        // A default container must not receive CAP_SYS_ADMIN, which would let it
        // write /proc/sys/kernel/core_pattern and escape to guest-root. Cover both
        // construction paths: the no-argument init (property default) and the full
        // memberwise init (parameter default).
        let viaProperty = LinuxProcessConfiguration()
        let viaInit = LinuxProcessConfiguration(arguments: ["/bin/sh"])

        for caps in [viaProperty.capabilities, viaInit.capabilities] {
            for set in [caps.bounding, caps.effective, caps.permitted, caps.inheritable, caps.ambient] {
                #expect(!set.contains(.sysAdmin), "default capabilities must not include CAP_SYS_ADMIN")
            }
        }

        // The default must be exactly the documented OCI baseline.
        let expected = LinuxCapabilities.defaultOCICapabilities
        #expect(viaProperty.capabilities.bounding == expected.bounding)
        #expect(viaProperty.capabilities.effective == expected.effective)
        #expect(viaProperty.capabilities.permitted == expected.permitted)
        #expect(viaProperty.capabilities.inheritable == expected.inheritable)
        #expect(viaProperty.capabilities.ambient == expected.ambient)
        #expect(viaInit.capabilities.bounding == expected.bounding)
    }

    @Test func defaultMaskedAndReadonlyPathsAreOCISet() {
        // Regression guard: masked/readonly paths must default to the OCI
        // standard set now that capabilities default to the restricted baseline.
        // Without CAP_SYS_ADMIN a workload can't unmount these, so the defaults
        // are meaningful defense-in-depth — shipping empty defaults would leave
        // /proc/kcore and friends exposed. Cover both construction paths and
        // both configuration types.
        let expectedMasked = LinuxContainer.defaultMaskedPaths()
        let expectedReadonly = LinuxContainer.defaultReadonlyPaths()

        // Sensitive kernel paths must actually be in the defaults.
        #expect(expectedMasked.contains("/proc/kcore"))
        #expect(expectedMasked.contains("/sys/firmware"))
        #expect(expectedReadonly.contains("/proc/sys"))

        let containerViaProperty = LinuxContainer.Configuration()
        let containerViaInit = LinuxContainer.Configuration(process: LinuxProcessConfiguration(arguments: ["/bin/sh"]))
        let pod = LinuxPod.ContainerConfiguration()

        for config in [containerViaProperty, containerViaInit] {
            #expect(config.maskedPaths == expectedMasked)
            #expect(config.readonlyPaths == expectedReadonly)
        }
        #expect(pod.maskedPaths == expectedMasked)
        #expect(pod.readonlyPaths == expectedReadonly)
    }

    @Test func containerResourcesDefaults() {
        // The container's cgroup limit is always set — there is no "unlimited"
        // state — so the defaults must match the VM sizing defaults on both facades.
        let resources = ContainerResources()
        #expect(resources.cpus == 4)
        #expect(resources.memoryInBytes == 1024.mib())

        let explicit = ContainerResources(cpus: 2, memoryInBytes: 512.mib())
        #expect(explicit.cpus == 2)
        #expect(explicit.memoryInBytes == 512.mib())
    }

    /// A `VirtualMachineManager` that records the configuration it is handed and
    /// then refuses to boot. `LinuxContainer.create()` builds the `VMConfiguration`
    /// and passes it straight to `vmm.create`, so this captures the VM sizing
    /// without needing a real VM.
    private final class StubVMM: VirtualMachineManager {
        private let captured = Mutex<VMConfiguration?>(nil)

        /// The configuration `LinuxContainer.create()` asked for, if it got that far.
        var capturedConfiguration: VMConfiguration? {
            captured.withLock { $0 }
        }

        func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
            captured.withLock { $0 = config.configuration }
            throw ContainerizationError(.unsupported, message: "stub")
        }
    }

    @Test func runtimeSpecUsesResourcesNotVMSize() async throws {
        // Regression guard for the split: the OCI cgroup limit must come from
        // `resources`, never from the fields that size the VM. If these are ever
        // reconnected, a caller asking for a big sandbox silently gets a big
        // cgroup quota too.
        let vmm = StubVMM()
        let container = try LinuxContainer(
            "sizing-test",
            rootfs: .block(format: "ext4", source: "/dev/null", destination: "/", options: []),
            vmm: vmm
        ) { config in
            config.process.arguments = ["/bin/true"]
            config.cpus = 8
            config.memoryInBytes = 2048.mib()
            config.resources = ContainerResources(cpus: 2, memoryInBytes: 512.mib())
        }

        let spec = container.generateRuntimeSpec()
        #expect(spec.linux?.resources?.cpu?.quota == 200_000)
        #expect(spec.linux?.resources?.cpu?.period == 100_000)
        #expect(spec.linux?.resources?.memory?.limit == Int64(512.mib()))

        // The other half of the split: the VM must be sized from the VM fields,
        // with nothing added. Drive `create()` far enough to build the
        // `VMConfiguration` — the stub records it and then throws instead of
        // booting, so the error is expected.
        await #expect(throws: (any Error).self) {
            try await container.create()
        }

        let vmConfig = try #require(vmm.capturedConfiguration)
        #expect(vmConfig.cpus == 8)
        #expect(vmConfig.memoryInBytes == 2048.mib())
    }

    @Test func containerConfigurationDefaultResources() {
        // Both construction paths must agree, and both must match the VM defaults.
        let viaProperty = LinuxContainer.Configuration()
        let viaInit = LinuxContainer.Configuration(process: LinuxProcessConfiguration(arguments: ["/bin/sh"]))

        for config in [viaProperty, viaInit] {
            #expect(config.cpus == 4)
            #expect(config.memoryInBytes == 1024.mib())
            #expect(config.resources.cpus == 4)
            #expect(config.resources.memoryInBytes == 1024.mib())
        }
    }

    @Test func podContainerConfigurationDefaultResources() {
        // Both facades must expose the same field with the same default. Note the
        // behavior change this encodes: a pod container is now always capped,
        // where a nil `cpus` previously meant no cgroup limit at all.
        let config = LinuxPod.ContainerConfiguration()
        #expect(config.resources.cpus == 4)
        #expect(config.resources.memoryInBytes == 1024.mib())
    }

    @Test func guestMemoryOverheadIsOptInOnly() {
        // Pins the memory headroom the library used to add implicitly, so a
        // silent change is caught: `cctl` and other consumers add it at the call
        // site expecting the pre-split sandbox size.
        #expect(ContainerResources.guestMemoryOverhead == 128.mib())

        // The more important half: the constant is a value, not behavior. A
        // default configuration must show *no* gap between the sandbox and the
        // container — if the library ever starts applying the overhead itself,
        // callers that already add it would double-count.
        let container = LinuxContainer.Configuration()
        #expect(container.memoryInBytes == container.resources.memoryInBytes)
        #expect(container.cpus == container.resources.cpus)

        let pod = LinuxPod.Configuration()
        let podContainer = LinuxPod.ContainerConfiguration()
        #expect(pod.memoryInBytes == podContainer.resources.memoryInBytes)
        #expect(pod.cpus == podContainer.resources.cpus)
    }
}
