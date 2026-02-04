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

import Foundation

/// MediaTypes represent all supported OCI image content types for both metadata and layer formats.
/// Follows all distributable media types in: https://github.com/opencontainers/image-spec/blob/main/specs-go/v1/mediatype.go
public struct MediaTypes: Codable, Sendable {
    /// Specifies the media type for a content descriptor.
    public static let descriptor = "application/vnd.oci.descriptor.v1+json"

    /// Specifies the media type for the oci-layout.
    public static let layoutHeader = "application/vnd.oci.layout.header.v1+json"

    /// Specifies the media type for an image index.
    public static let index = "application/vnd.oci.image.index.v1+json"

    /// Specifies the media type for an image manifest.
    public static let imageManifest = "application/vnd.oci.image.manifest.v1+json"

    /// Specifies the media type for the image configuration.
    public static let imageConfig = "application/vnd.oci.image.config.v1+json"

    /// Specifies the media type for an unused blob containing the value "{}".
    public static let emptyJSON = "application/vnd.oci.empty.v1+json"

    /// Specifies the media type for a Docker image manifest.
    public static let dockerManifest = "application/vnd.docker.distribution.manifest.v2+json"

    /// Specifies the media type for a Docker image manifest list.
    public static let dockerManifestList = "application/vnd.docker.distribution.manifest.list.v2+json"

    /// The Docker media type used for image configurations.
    public static let dockerImageConfig = "application/vnd.docker.container.image.v1+json"

    /// The media type used for layers referenced by the manifest.
    public static let imageLayer = "application/vnd.oci.image.layer.v1.tar"

    /// The media type used for gzipped layers referenced by the manifest.
    public static let imageLayerGzip = "application/vnd.oci.image.layer.v1.tar+gzip"

    /// The media type used for zstd compressed layers referenced by the manifest.
    public static let imageLayerZstd = "application/vnd.oci.image.layer.v1.tar+zstd"

    /// The Docker media type used for uncompressed layers referenced by an image manifest.
    public static let dockerImageLayer = "application/vnd.docker.image.rootfs.diff.tar"

    /// The Docker media type used for gzipped layers referenced by an image manifest.
    public static let dockerImageLayerGzip = "application/vnd.docker.image.rootfs.diff.tar.gzip"

    /// The Docker media type used for zstd compressed layers referenced by an image manifest.
    public static let dockerImageLayerZstd = "application/vnd.docker.image.rootfs.diff.tar.zstd"

    /// The media type used for in-toto attestations blobs.
    public static let inTotoAttestationBlob = "application/vnd.in-toto+json"
}
