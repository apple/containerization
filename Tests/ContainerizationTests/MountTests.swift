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
