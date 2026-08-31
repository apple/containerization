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
import Foundation

extension Mount {
    /// Returns a `CloudHypervisor.DiskConfig` describing this mount as a virtio-blk
    /// device, or `nil` if the mount is not a block device.
    ///
    /// The caller supplies the device id; cloud-hypervisor uses it both as a
    /// stable handle for hotplug-remove and as the udev/sysfs identifier inside
    /// the guest.
    ///
    /// `imageType` defaults to `.raw` because Containerization mounts are
    /// always raw block files (ext4 produced by the EXT4 unpacker, NBD URLs,
    /// etc.). When cloud-hypervisor doesn't see an `image_type` it falls
    /// back to `Unknown` and silently rejects all writes — see CH's
    /// `virtio-devices/src/block.rs` "Attempting to write to sector 0 on a
    /// disk without specifying image_type" warning.
    public func chDiskConfig(id: String) -> CloudHypervisor.DiskConfig? {
        guard case .virtioblk = self.runtimeOptions else {
            return nil
        }
        return CloudHypervisor.DiskConfig(
            path: self.source,
            readonly: self.options.contains("ro"),
            direct: nil,
            iommu: nil,
            id: id,
            pciSegment: nil,
            imageType: .raw
        )
    }

    /// Returns a `CloudHypervisor.FsConfig` describing this mount as a virtio-fs
    /// share served by an out-of-process `virtiofsd`, or `nil` if the mount is
    /// not a virtiofs share.
    ///
    /// `tag` is the guest-side mount tag and `socketPath` is the UDS path the
    /// virtiofsd subprocess publishes. Both are owned by the caller.
    public func chFsConfig(tag: String, socketPath: String, id: String) -> CloudHypervisor.FsConfig? {
        guard case .virtiofs = self.runtimeOptions else {
            return nil
        }
        return CloudHypervisor.FsConfig(
            tag: tag,
            socket: socketPath,
            numQueues: nil,
            queueSize: nil,
            id: id,
            pciSegment: nil
        )
    }
}

/// Build the host-side UDS path for a virtiofsd ↔ cloud-hypervisor socket.
///
/// `tag` is the full source-hash (used as the FUSE tag advertised to the
/// guest); the socket *path* uses only an 8-char prefix because the full
/// path — `<workDir>/virtiofs-<tag>.sock` with a 36-char tag — overshoots
/// Linux's 108-byte `SUN_LEN` limit. 32 bits of disambiguation is more
/// than enough within a single VM (handful of distinct virtiofs sources).
func chVirtiofsSocketURL(workDir: URL, tag: String) -> URL {
    let short = String(tag.prefix(8))
    return workDir.appendingPathComponent("vfs-\(short).sock")
}
