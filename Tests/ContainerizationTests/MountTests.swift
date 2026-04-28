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

struct MountTests {

    @Test func mountShareCreatesVirtiofsMount() {
        let mount = Mount.share(
            source: "/host/shared",
            destination: "/guest/shared",
            options: ["rw", "noatime"],
            runtimeOptions: ["tag=shared"]
        )

        #expect(mount.type == "virtiofs")
        #expect(mount.source == "/host/shared")
        #expect(mount.destination == "/guest/shared")
        #expect(mount.options == ["rw", "noatime"])

        if case .virtiofs(let opts) = mount.runtimeOptions {
            #expect(opts == ["tag=shared"])
        } else {
            #expect(Bool(false), "Expected virtiofs runtime options")
        }
    }

    @Test func sortMountsByDestinationDepthPreventsParentShadowing() {
        let mounts: [ContainerizationOCI.Mount] = [
            .init(destination: "/tmp/foo/bar"),
            .init(destination: "/tmp"),
            .init(destination: "/var/log/app"),
            .init(destination: "/var"),
        ]

        let sorted = sortMountsByDestinationDepth(mounts)

        #expect(
            sorted.map(\.destination) == [
                "/tmp",
                "/var",
                "/tmp/foo/bar",
                "/var/log/app",
            ])
    }

    @Test func sortMountsByDestinationDepthPreservesOrderForEqualDepth() {
        let mounts: [ContainerizationOCI.Mount] = [
            .init(destination: "/b"),
            .init(destination: "/a"),
            .init(destination: "/c"),
        ]

        let sorted = sortMountsByDestinationDepth(mounts)

        // All same depth, order should be preserved (stable sort).
        #expect(sorted.map(\.destination) == ["/b", "/a", "/c"])
    }

    @Test func sortMountsByDestinationDepthHandlesTrailingAndDoubleSlashes() {
        let mounts: [ContainerizationOCI.Mount] = [
            .init(destination: "/a//b/c"),
            .init(destination: "/a/"),
        ]

        let sorted = cleanAndSortMounts(mounts)

        // Paths are cleaned: "/a/" -> "/a", "/a//b/c" -> "/a/b/c"
        #expect(sorted.map(\.destination) == ["/a", "/a/b/c"])
    }

    @Test func sortMountsByDestinationDepthCleansDotAndDotDot() {
        let mounts: [ContainerizationOCI.Mount] = [
            .init(destination: "/tmp/../foo"),
            .init(destination: "/tmp/./bar/baz"),
            .init(destination: "/"),
        ]

        let sorted = cleanAndSortMounts(mounts)

        // "/tmp/../foo" -> "/foo", "/tmp/./bar/baz" -> "/tmp/bar/baz"
        #expect(sorted.map(\.destination) == ["/", "/foo", "/tmp/bar/baz"])
    }
}

@Suite("AttachedFilesystem runtimeOptions dispatch")
struct AttachedFilesystemTests {

    @Test func virtioblkMountAllocatesBlockDevice() throws {
        let mount = Mount.block(
            format: "ext4",
            source: "/path/to/disk.img",
            destination: "/data"
        )
        let allocator = Character.blockDeviceTagAllocator()
        let attached = try AttachedFilesystem(mount: mount, allocator: allocator)

        #expect(attached.source == "/dev/vda")
        #expect(attached.type == "ext4")
        #expect(attached.destination == "/data")
    }

    @Test func nbdMountAllocatesBlockDevice() throws {
        let mount = Mount.block(
            format: "ext4",
            source: "nbd://localhost:10809",
            destination: "/data"
        )
        let allocator = Character.blockDeviceTagAllocator()
        let attached = try AttachedFilesystem(mount: mount, allocator: allocator)

        #expect(attached.source == "/dev/vda")
        #expect(attached.type == "ext4")
        #expect(attached.destination == "/data")
    }

    @Test func nbdMountWithNonExt4FormatAllocatesBlockDevice() throws {
        let mount = Mount.block(
            format: "xfs",
            source: "nbd://localhost:10809",
            destination: "/data"
        )
        let allocator = Character.blockDeviceTagAllocator()
        let attached = try AttachedFilesystem(mount: mount, allocator: allocator)

        #expect(attached.source == "/dev/vda")
        #expect(attached.type == "xfs")
    }

    @Test func multipleBlockDevicesAllocateSequentially() throws {
        let allocator = Character.blockDeviceTagAllocator()

        let m1 = Mount.block(format: "ext4", source: "/disk1.img", destination: "/a")
        let m2 = Mount.block(format: "ext4", source: "nbd://host:10809", destination: "/b")
        let m3 = Mount.block(format: "ext4", source: "/disk2.img", destination: "/c")

        let a1 = try AttachedFilesystem(mount: m1, allocator: allocator)
        let a2 = try AttachedFilesystem(mount: m2, allocator: allocator)
        let a3 = try AttachedFilesystem(mount: m3, allocator: allocator)

        #expect(a1.source == "/dev/vda")
        #expect(a2.source == "/dev/vdb")
        #expect(a3.source == "/dev/vdc")
    }

    @Test func anyMountUsesSourceDirectly() throws {
        let mount = Mount.any(
            type: "tmpfs",
            source: "tmpfs",
            destination: "/tmp"
        )
        let allocator = Character.blockDeviceTagAllocator()
        let attached = try AttachedFilesystem(mount: mount, allocator: allocator)

        #expect(attached.source == "tmpfs")
    }
}

@Suite("PodVolume and shared mount types")
struct PodVolumeTests {

    @Test func podVolumeNBDSourceCreation() {
        let volume = LinuxPod.PodVolume(
            name: "shared-data",
            source: .nbd(url: URL(string: "nbd://localhost:10809")!),
            format: "ext4"
        )

        #expect(volume.name == "shared-data")
        #expect(volume.format == "ext4")
        if case .nbd(let url, let timeout, let readOnly) = volume.source {
            #expect(url.absoluteString == "nbd://localhost:10809")
            #expect(timeout == nil)
            #expect(readOnly == false)
        } else {
            Issue.record("Expected .nbd source")
        }
    }

    @Test func podVolumeNBDSourceWithOptions() {
        let volume = LinuxPod.PodVolume(
            name: "data",
            source: .nbd(url: URL(string: "nbd://host:10809")!, timeout: 30, readOnly: true),
            format: "xfs"
        )

        if case .nbd(_, let timeout, let readOnly) = volume.source {
            #expect(timeout == 30)
            #expect(readOnly == true)
        } else {
            Issue.record("Expected .nbd source")
        }
    }

    @Test func podVolumeToMountConvertsCorrectly() {
        let volume = LinuxPod.PodVolume(
            name: "my-vol",
            source: .nbd(url: URL(string: "nbd://host:10809/export")!),
            format: "ext4"
        )

        let mount = volume.toMount()

        #expect(mount.source == "nbd://host:10809/export")
        #expect(mount.destination == "/run/volumes/my-vol")
        #expect(mount.type == "ext4")
        #expect(mount.isBlock)
    }

    @Test func podVolumeToMountWithReadOnlySetsOptions() {
        let volume = LinuxPod.PodVolume(
            name: "ro-vol",
            source: .nbd(url: URL(string: "nbd://host:10809")!, readOnly: true),
            format: "ext4"
        )

        let mount = volume.toMount()

        #expect(mount.options.contains("ro"))
        #expect(mount.isBlock)
    }

    @Test func podVolumeToMountWithTimeoutSetsRuntimeOption() {
        let volume = LinuxPod.PodVolume(
            name: "data",
            source: .nbd(url: URL(string: "nbd://host:10809")!, timeout: 60),
            format: "ext4"
        )

        let mount = volume.toMount()

        if case .virtioblk(let opts) = mount.runtimeOptions {
            #expect(opts.contains("vzTimeout=60.0"))
        } else {
            Issue.record("Expected virtioblk runtime options")
        }
    }

    @Test func podVolumeToMountUsesMountType() {
        let volume = LinuxPod.PodVolume(
            name: "data",
            source: .nbd(url: URL(string: "nbd://host:10809")!),
            format: "xfs"
        )

        let mount = volume.toMount()

        #expect(mount.type == "xfs")
    }

    @Test func sharedMountCreation() {
        let mount = Mount.sharedMount(
            name: "shared-data",
            destination: "/data",
            options: ["ro"]
        )

        #expect(mount.source == "shared-data")
        #expect(mount.destination == "/data")
        #expect(mount.options == ["ro"])
        #expect(mount.type == "none")
        if case .shared = mount.runtimeOptions {
            // correct
        } else {
            Issue.record("Expected .shared runtime options")
        }
    }

    @Test func sharedMountDefaultOptions() {
        let mount = Mount.sharedMount(name: "data", destination: "/mnt")

        #expect(mount.options.isEmpty)
    }

    @Test func sharedMountIsNotBlock() {
        let mount = Mount.sharedMount(name: "data", destination: "/mnt")

        #expect(!mount.isBlock)
    }

    @Test func sharedMountDoesNotAllocateBlockDevice() throws {
        let allocator = Character.blockDeviceTagAllocator()

        // Shared mount should not consume a device letter.
        let shared = Mount.sharedMount(name: "vol", destination: "/data")
        let attached = try AttachedFilesystem(mount: shared, allocator: allocator)
        #expect(attached.source == "vol")

        // Next block device should still get vda.
        let block = Mount.block(format: "ext4", source: "/disk.img", destination: "/mnt")
        let blockAttached = try AttachedFilesystem(mount: block, allocator: allocator)
        #expect(blockAttached.source == "/dev/vda")
    }
}
