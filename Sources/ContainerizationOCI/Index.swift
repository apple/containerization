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

//  Source: https://github.com/opencontainers/image-spec/blob/main/specs-go/v1/index.go

import Foundation

/// Index references manifests for various platforms.
/// This structure provides `application/vnd.oci.image.index.v1+json` mediatype when marshalled to JSON.
public struct Index: Codable, Sendable {
    /// schemaVersion is the image manifest schema that this image follows
    public let schemaVersion: Int

    /// mediaType specifies the type of this document data structure e.g. `application/vnd.oci.image.index.v1+json`
    /// This field is optional per the OCI Image Index Specification (omitempty)
    public let mediaType: String

    /// manifests references platform specific manifests.
    public var manifests: [Descriptor]

    /// annotations contains arbitrary metadata for the image index.
    public var annotations: [String: String]?

    public init(
        schemaVersion: Int = 2, mediaType: String = MediaTypes.index, manifests: [Descriptor],
        annotations: [String: String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.manifests = manifests
        self.annotations = annotations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType) ?? ""
        self.manifests = try container.decode([Descriptor].self, forKey: .manifests)
        self.annotations = try container.decodeIfPresent([String: String].self, forKey: .annotations)
    }
}
