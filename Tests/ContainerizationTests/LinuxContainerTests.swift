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

    /// A `VirtualMachineManager` that cannot create anything. `LinuxContainer.init`
    /// only stores the manager, so nothing below should reach `create`.
    private struct UnusableVMM: VirtualMachineManager {
        func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
            throw ContainerizationError(.unsupported, message: "test stub: no VM should be created here")
        }
    }

    private static let testRootfs = Mount.block(format: "ext4", source: "/tmp/does-not-need-to-exist.ext4", destination: "/")

    @Test func seccompProfileIsValidatedAtInit() throws {
        var config = LinuxContainer.Configuration()
        config.process.arguments = ["/bin/true"]
        config.seccompProfile = .default

        // vmexec ignores spec.linux.seccomp, so a profile without an OCI
        // runtime is a sandbox that does not exist. Rejected at init, before
        // the caller has booted a VM.
        #expect(throws: ContainerizationError.self) {
            _ = try LinuxContainer("seccomp-without-runtime", rootfs: Self.testRootfs, vmm: UnusableVMM(), configuration: config)
        }

        config.ociRuntimePath = "/sbin/runc"
        #expect(throws: Never.self) {
            _ = try LinuxContainer("seccomp-with-runtime", rootfs: Self.testRootfs, vmm: UnusableVMM(), configuration: config)
        }

        // The default is unfiltered, and needs no runtime.
        var unconfined = LinuxContainer.Configuration()
        unconfined.process.arguments = ["/bin/true"]
        #expect(throws: Never.self) {
            _ = try LinuxContainer("no-seccomp", rootfs: Self.testRootfs, vmm: UnusableVMM(), configuration: unconfined)
        }
    }

    /// A custom profile is subject to the same rule as `.default`: `vmexec`
    /// ignores both identically, so neither may be accepted without an OCI
    /// runtime.
    @Test func customSeccompProfileIsValidatedAtInit() throws {
        let profile = LinuxSeccomp(
            defaultAction: .actAllow,
            defaultErrnoRet: nil,
            architectures: [],
            flags: [],
            listenerPath: "",
            listenerMetadata: "",
            syscalls: [
                LinuxSyscall(names: ["mkdir", "mkdirat"], action: .actErrno, errnoRet: 13, args: [])
            ]
        )

        var config = LinuxContainer.Configuration()
        config.process.arguments = ["/bin/true"]
        config.seccompProfile = .profile(profile)

        #expect(throws: ContainerizationError.self) {
            _ = try LinuxContainer("custom-seccomp-without-runtime", rootfs: Self.testRootfs, vmm: UnusableVMM(), configuration: config)
        }

        config.ociRuntimePath = "/sbin/runc"
        #expect(throws: Never.self) {
            _ = try LinuxContainer("custom-seccomp-with-runtime", rootfs: Self.testRootfs, vmm: UnusableVMM(), configuration: config)
        }
    }

    @Test func vmResourcesDefaults() {
        for resources in [VMResources(), VMResources.default] {
            #expect(resources.cpus == 4)
            #expect(resources.memoryInBytes == 1024.mib())
        }

        let explicit = VMResources(cpus: 2, memoryInBytes: 512.mib())
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

    @Test func runtimeSpecUsesContainerLimitsNotVMSize() async throws {
        // The OCI cgroup limit comes from the container configuration, the VM size from `vm`.
        let vmm = StubVMM()
        let container = try LinuxContainer(
            "sizing-test",
            rootfs: .block(format: "ext4", source: "/dev/null", destination: "/", options: []),
            vmm: vmm,
            vm: VMResources(cpus: 8, memoryInBytes: 2048.mib())
        ) { config in
            config.process.arguments = ["/bin/true"]
            config.cpus = 2
            config.memoryInBytes = 512.mib()
        }

        let spec = try container.generateRuntimeSpec(for: .containerInit)
        #expect(spec.linux?.resources?.cpu?.quota == 200_000)
        #expect(spec.linux?.resources?.cpu?.period == 100_000)
        #expect(spec.linux?.resources?.memory?.limit == Int64(512.mib()))

        // The VM must be sized from `vm`, with nothing added. Drive `create()` far enough to build the
        // `VMConfiguration` — the stub records it and then throws instead of
        // booting, so the error is expected.
        await #expect(throws: (any Error).self) {
            try await container.create()
        }

        let vmConfig = try #require(vmm.capturedConfiguration)
        #expect(vmConfig.cpus == 8)
        #expect(vmConfig.memoryInBytes == 2048.mib())
    }

    @Test func containerConfigurationDefaultLimits() {
        let viaProperty = LinuxContainer.Configuration()
        let viaInit = LinuxContainer.Configuration(process: LinuxProcessConfiguration(arguments: ["/bin/sh"]))

        for config in [viaProperty, viaInit] {
            #expect(config.cpus == 4)
            #expect(config.memoryInBytes == 1024.mib())
        }
    }

    @Test func podContainerConfigurationDefaultLimits() {
        // A pod container is always capped; a nil `cpus` previously meant no cgroup limit.
        let config = LinuxPod.ContainerConfiguration()
        #expect(config.cpus == 4)
        #expect(config.memoryInBytes == 1024.mib())
    }

    @Test func guestMemoryOverheadIsOptInOnly() {
        // `cctl` adds this at the call site; the library must never apply it itself.
        #expect(VMResources.guestMemoryOverhead == 128.mib())

        let vm = VMResources.default
        let container = LinuxContainer.Configuration()
        #expect(vm.memoryInBytes == container.memoryInBytes)
        #expect(vm.cpus == container.cpus)

        let podContainer = LinuxPod.ContainerConfiguration()
        #expect(vm.memoryInBytes == podContainer.memoryInBytes)
        #expect(vm.cpus == podContainer.cpus)
    }
}
