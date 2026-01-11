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

//  Source: https://github.com/opencontainers/image-spec/blob/main/specs-go/v1/manifest.go

import Foundation

/// Manifest provides `application/vnd.oci.image.manifest.v1+json` mediatype structure when marshalled to JSON.
public struct Manifest: Codable, Sendable {
    /// `schemaVersion` is the image manifest schema that this image follows.
    public let schemaVersion: Int

    /// `mediaType` specifies the type of this document data structure, e.g. `application/vnd.oci.image.manifest.v1+json`.
    public let mediaType: String?

    /// `config` references a configuration object for a container, by digest.
    /// The referenced configuration object is a JSON blob that the runtime uses to set up the container.
    public let config: Descriptor

    /// `layers` is an indexed list of layers referenced by the manifest.
    public let layers: [Descriptor]

    /// `annotations` contains arbitrary metadata for the image manifest.
    public let annotations: [String: String]?

    public init(
        schemaVersion: Int = 2, mediaType: String = MediaTypes.imageManifest, config: Descriptor, layers: [Descriptor],
        annotations: [String: String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.config = config
        self.layers = layers
        self.annotations = annotations
    }
}
