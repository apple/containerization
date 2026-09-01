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

import Containerization
import Foundation
import Testing

@testable import cctl

@Suite("cctl run --block argument parsing")
struct BlockArgumentTests {

    @Test func nbdSourcePreservesURLColons() throws {
        let mount = try Containerization.Mount.parseBlockArgument(
            "src=nbd://127.0.0.1:10809,dst=/data,fmt=ext4"
        )

        #expect(mount.source == "nbd://127.0.0.1:10809")
        #expect(mount.destination == "/data")
        #expect(mount.type == "ext4")
        #expect(mount.isBlock)
        #expect(mount.options.isEmpty)
    }

    @Test func nbdUnixSocketURLSurvivesParsing() throws {
        let mount = try Containerization.Mount.parseBlockArgument(
            "src=nbd+unix:///?socket=/tmp/nbd.sock,dst=/data"
        )

        #expect(mount.source == "nbd+unix:///?socket=/tmp/nbd.sock")
        #expect(mount.destination == "/data")
    }

    @Test func formatDefaultsToExt4() throws {
        let mount = try Containerization.Mount.parseBlockArgument("src=/tmp/disk.ext4,dst=/mnt")

        #expect(mount.type == "ext4")
    }

    @Test func formatIsPassedThroughVerbatim() throws {
        let mount = try Containerization.Mount.parseBlockArgument("src=/tmp/disk.img,dst=/mnt,fmt=xfs")

        #expect(mount.type == "xfs")
    }

    @Test func readOnlySetsMountOption() throws {
        let mount = try Containerization.Mount.parseBlockArgument("src=/tmp/disk.ext4,dst=/mnt,ro")

        #expect(mount.options == ["ro"])
    }

    @Test func rawUsesBindMountAndDiscardsFormat() throws {
        // A raw attachment bind mounts the device node, so no filesystem type
        // is interpreted even when fmt= is supplied.
        let mount = try Containerization.Mount.parseBlockArgument(
            "src=nbd://host:10809,dst=/dev/my-disk,fmt=ext4,raw"
        )

        #expect(mount.type == "none")
        #expect(mount.options == ["bind"])
        #expect(mount.isBlock)
    }

    @Test func rawReadOnlyEmitsBothOptions() throws {
        // MS_RDONLY is ignored on the initial bind, so ContainerizationOS
        // needs both options present to trigger its remount pass.
        let mount = try Containerization.Mount.parseBlockArgument("src=/tmp/disk.img,dst=/dev/d,raw,ro")

        #expect(mount.options == ["bind", "ro"])
    }

    @Test func timeoutBecomesVZRuntimeOption() throws {
        let mount = try Containerization.Mount.parseBlockArgument(
            "src=nbd://host:10809,dst=/data,timeout=30"
        )

        if case .virtioblk(let opts) = mount.runtimeOptions {
            #expect(opts == ["vzTimeout=30"])
        } else {
            Issue.record("Expected virtioblk runtime options")
        }
    }

    @Test func noTimeoutLeavesRuntimeOptionsEmpty() throws {
        let mount = try Containerization.Mount.parseBlockArgument("src=/tmp/disk.ext4,dst=/mnt")

        if case .virtioblk(let opts) = mount.runtimeOptions {
            #expect(opts.isEmpty)
        } else {
            Issue.record("Expected virtioblk runtime options")
        }
    }

    @Test func missingSourceThrows() {
        #expect(throws: (any Error).self) {
            try Containerization.Mount.parseBlockArgument("dst=/data")
        }
    }

    @Test func missingDestinationThrows() {
        #expect(throws: (any Error).self) {
            try Containerization.Mount.parseBlockArgument("src=/tmp/disk.ext4")
        }
    }

    @Test func emptySourceValueThrows() {
        #expect(throws: (any Error).self) {
            try Containerization.Mount.parseBlockArgument("src=,dst=/data")
        }
    }

    @Test func unknownFieldThrows() {
        #expect(throws: (any Error).self) {
            try Containerization.Mount.parseBlockArgument("src=/tmp/d.img,dst=/mnt,bogus=1")
        }
    }

    @Test func nonNumericTimeoutThrows() {
        #expect(throws: (any Error).self) {
            try Containerization.Mount.parseBlockArgument("src=/tmp/d.img,dst=/mnt,timeout=abc")
        }
    }

    @Test func valuelessFieldRequiringValueThrows() {
        // `src` without `=value` is a flag-shaped field and must not silently
        // parse as an empty source.
        #expect(throws: (any Error).self) {
            try Containerization.Mount.parseBlockArgument("src,dst=/mnt")
        }
    }

    @Test func flagFieldWithValueThrows() {
        #expect(throws: (any Error).self) {
            try Containerization.Mount.parseBlockArgument("src=/tmp/d.img,dst=/mnt,ro=true")
        }
    }
}
