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

import CloudHypervisor
import Testing

@testable import Containerization

@Suite("Mount+CH")
struct MountCHTests {
    @Test("block mount without options produces DiskConfig with readonly=false")
    func blockNoOptions() {
        let mount = Mount.block(format: "ext4", source: "/foo.img", destination: "/data")
        let cfg = mount.chDiskConfig(id: "blk-0")
        #expect(cfg?.path == "/foo.img")
        #expect(cfg?.readonly == false)
        #expect(cfg?.id == "blk-0")
        #expect(cfg?.direct == nil)
        #expect(cfg?.iommu == nil)
        #expect(cfg?.pciSegment == nil)
    }

    @Test("block mount with 'ro' option produces DiskConfig with readonly=true")
    func blockReadOnly() {
        let mount = Mount.block(format: "ext4", source: "/foo.img", destination: "/data", options: ["ro"])
        let cfg = mount.chDiskConfig(id: "blk-1")
        #expect(cfg?.readonly == true)
    }

    @Test("non-block mount returns nil from chDiskConfig")
    func chDiskConfigNilForNonBlock() {
        let share = Mount.share(source: "/host", destination: "/guest")
        #expect(share.chDiskConfig(id: "x") == nil)

        let any = Mount.any(type: "tmpfs", source: "tmpfs", destination: "/tmp")
        #expect(any.chDiskConfig(id: "x") == nil)
    }

    @Test("share mount produces FsConfig with tag and socket")
    func shareMount() {
        let mount = Mount.share(source: "/host/dir", destination: "/guest/dir")
        let cfg = mount.chFsConfig(tag: "share0", socketPath: "/tmp/vfs.sock", id: "fs-0")
        #expect(cfg?.tag == "share0")
        #expect(cfg?.socket == "/tmp/vfs.sock")
        #expect(cfg?.id == "fs-0")
        #expect(cfg?.numQueues == nil)
        #expect(cfg?.queueSize == nil)
        #expect(cfg?.pciSegment == nil)
    }

    @Test("non-share mount returns nil from chFsConfig")
    func chFsConfigNilForNonShare() {
        let block = Mount.block(format: "ext4", source: "/foo.img", destination: "/data")
        #expect(block.chFsConfig(tag: "t", socketPath: "/s", id: "x") == nil)

        let any = Mount.any(type: "tmpfs", source: "tmpfs", destination: "/tmp")
        #expect(any.chFsConfig(tag: "t", socketPath: "/s", id: "x") == nil)
    }
}
