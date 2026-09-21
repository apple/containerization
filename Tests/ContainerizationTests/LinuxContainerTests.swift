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
}
