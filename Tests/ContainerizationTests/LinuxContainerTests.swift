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

    @Test func trimTargetsOnlyWritableBlockFilesystems() throws {
        // A trim with no paths has to pick its own targets, and every
        // filesystem it names that cannot discard fails the whole call.
        let container = try LinuxContainer("trim", rootfs: Self.ext4("/tmp/rootfs.ext4"), vmm: StubVirtualMachineManager()) { config in
            config.mounts += [
                Self.ext4("/tmp/data.ext4", at: "/data"),
                Self.ext4("/tmp/reference.ext4", at: "/reference", options: ["ro"]),
                .share(source: "/tmp/share", destination: "/share"),
            ]
        }

        // The default mounts are proc, sysfs, tmpfs and friends: no device, nothing
        // to discard. The root filesystem is named where the runtime mounted it.
        #expect(
            container.trimTargets == [
                .sandbox(path: "/run/container/trim/rootfs"),
                .container(id: "trim", path: "/data"),
            ])
    }

    @Test func trimReachesAWritableLayerThroughTheSandbox() throws {
        // The container's own root is an overlay, which has no discard of its
        // own, and the ext4 beneath it is left behind by pivot_root — so the
        // trim has to name it where the sandbox still has it mounted.
        let container = try LinuxContainer(
            "trim-overlay",
            rootfs: Self.ext4("/tmp/rootfs.ext4"),
            writableLayer: Self.ext4("/tmp/upper.ext4"),
            vmm: StubVirtualMachineManager()
        ) { config in
            config.mounts = [Self.ext4("/tmp/data.ext4", at: "/data")]
        }

        #expect(
            container.trimTargets == [
                .sandbox(path: "/run/container/trim-overlay/upper"),
                .container(id: "trim-overlay", path: "/data"),
            ])
    }

    @Test func podTrimNamesVolumesWhereThePodMountedThem() throws {
        // A container reaches a pod volume through a bind, but the pod mounts it
        // once in the sandbox — which is where the trim has to name it so that it
        // happens once and keeps working when a container's namespace is gone.
        let targets = LinuxPod.trimTargets(
            containerID: "c1",
            rootfs: Self.ext4("/tmp/rootfs.ext4"),
            mounts: [
                Self.ext4("/tmp/data.ext4", at: "/data"),
                .sharedMount(name: "disk", destination: "/disk"),
                .sharedMount(name: "scratch", destination: "/scratch"),
                .sharedMount(name: "archive", destination: "/archive"),
                .sharedMount(name: "absent", destination: "/absent"),
            ],
            volumes: [
                .init(name: "disk", source: .diskImage(path: URL(filePath: "/tmp/disk.ext4")), format: "ext4"),
                .init(name: "scratch", source: .tmpfs(), format: "tmpfs"),
                .init(name: "archive", source: .diskImage(path: URL(filePath: "/tmp/archive.ext4"), readOnly: true), format: "ext4"),
            ]
        )

        #expect(
            targets == [
                .sandbox(path: "/run/container/c1/rootfs"),
                .container(id: "c1", path: "/data"),
                .sandbox(path: "/run/volumes/disk"),
            ])
    }

    private static func ext4(_ source: String, at destination: String = "/", options: [String] = []) -> Containerization.Mount {
        .block(format: "ext4", source: source, destination: destination, options: options)
    }
}

private struct StubVirtualMachineManager: VirtualMachineManager {
    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        throw ContainerizationError(.unsupported, message: "create")
    }
}
