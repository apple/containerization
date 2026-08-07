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

import ContainerizationOCI

extension VirtualMachineAgent {
    /// Mount a container's rootfs as an overlay, with the image as the lower
    /// layer and the container's writable layer as the upper, so that writes
    /// land in the layer and the image stays as it is.
    func mountOverlayRootfs(
        containerID: String,
        rootfsAttachment: AttachedFilesystem,
        writableAttachment: AttachedFilesystem,
        rootfsPath: String
    ) async throws {
        let lowerPath = "/run/container/\(containerID)/lower"
        let upperMountPath = "/run/container/\(containerID)/upper"
        let upperPath = "/run/container/\(containerID)/upper/diff"
        let workPath = "/run/container/\(containerID)/upper/work"

        // Mount the image (lower layer) as read-only.
        var lowerMount = rootfsAttachment.to
        lowerMount.destination = lowerPath
        if !lowerMount.options.contains("ro") {
            lowerMount.options.append("ro")
        }
        try await self.mount(lowerMount)

        // Mount the writable layer.
        var upperMount = writableAttachment.to
        upperMount.destination = upperMountPath
        try await self.mount(upperMount)

        // Create the upper and work directories inside the writable layer.
        try await self.mkdir(path: upperPath, all: true, perms: 0o755)
        try await self.mkdir(path: workPath, all: true, perms: 0o755)

        // Mount the overlay.
        let overlayMount = ContainerizationOCI.Mount(
            type: "overlay",
            source: "overlay",
            destination: rootfsPath,
            options: [
                "lowerdir=\(lowerPath)",
                "upperdir=\(upperPath)",
                "workdir=\(workPath)",
            ]
        )
        try await self.mount(overlayMount)
    }
}
