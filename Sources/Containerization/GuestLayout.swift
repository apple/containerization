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

/// Sandbox paths shared by mount setup, trimming, and teardown. These paths
/// remain outside the container's root after pivot_root.
package enum GuestLayout {
    /// The container's root, which is the image's filesystem directly or an
    /// overlay assembled from ``lowerLayer(_:)`` and ``writableLayer(_:)``.
    package static func rootfs(_ containerID: String) -> String {
        "\(runtimeDirectory(containerID))/rootfs"
    }

    /// The image's filesystem, mounted read-only as an overlay's lower layer.
    package static func lowerLayer(_ containerID: String) -> String {
        "\(runtimeDirectory(containerID))/lower"
    }

    /// The filesystem every write to an overlay root lands on.
    package static func writableLayer(_ containerID: String) -> String {
        "\(runtimeDirectory(containerID))/upper"
    }

    /// A volume the pod mounts once and binds into the containers that ask for it.
    package static func volume(_ name: String) -> String {
        "/run/volumes/\(name)"
    }

    /// The guest's OCI bundle directory; its rootfs path must match ``rootfs(_:)``.
    package static func runtimeDirectory(_ containerID: String) -> String {
        "/run/container/\(containerID)"
    }

    /// Where a relayed unix socket is staged, outside any container's rootfs so
    /// that neither symlink traversal nor a later mount can shadow it.
    package static func socketStaging(_ socketID: String) -> String {
        "/run/sockets/\(socketID).sock"
    }
}
