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

//  Source: https://github.com/opencontainers/image-spec/blob/main/specs-go/v1/descriptor.go

import Foundation

/// Descriptor describes the disposition of targeted content.
/// This structure provides `application/vnd.oci.descriptor.v1+json` mediatype
/// when marshalled to JSON.
public struct Descriptor: Codable, Sendable, Equatable {
    /// mediaType is the media type of the object this schema refers to.
    public let mediaType: String

    /// digest is the digest of the targeted content.
    public let digest: String

    /// size specifies the size in bytes of the blob.
    public let size: Int64

    /// urls specifies a list of URLs from which this object MAY be downloaded.
    public let urls: [String]?

    /// annotations contains arbitrary metadata relating to the targeted content.
    public var annotations: [String: String]?

    /// platform describes the platform which the image in the manifest runs on.
    ///
    /// This should only be used when referring to a manifest.
    public var platform: Platform?

    /// artifactType specifies the IANA media type of the artifact.
    ///
    /// Used in referrers API responses to indicate the type of each referring artifact.
    public let artifactType: String?

    public init(
        mediaType: String, digest: String, size: Int64, urls: [String]? = nil, annotations: [String: String]? = nil,
        platform: Platform? = nil, artifactType: String? = nil
    ) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.urls = urls
        self.annotations = annotations
        self.platform = platform
        self.artifactType = artifactType
    }

    enum CodingKeys: String, CodingKey {
        case mediaType
        case digest
        case size
        case urls
        case annotations
        case platform
        case artifactType
    }

    /// Decodes a descriptor, rejecting any digest that is not a well formed
    /// `sha256:<hex>` value.
    ///
    /// Descriptors are decoded straight from registry responses and from on-disk
    /// image layouts, and their digests are used as content store path
    /// components. Validating here means a manifest or index carrying a
    /// traversing digest such as `sha256:../../etc/hosts` is rejected at the
    /// trust boundary, before it can be written to the store and re-read later.
    ///
    /// The memberwise initializer is deliberately left non-throwing: every
    /// in-project construction site passes a locally computed digest.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let digest = try container.decode(String.self, forKey: .digest)
        do {
            _ = try ParsedDigest(parsing: digest)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .digest, in: container, debugDescription: "invalid content digest: \(error)")
        }

        let size = try container.decode(Int64.self, forKey: .size)
        guard size >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .size, in: container, debugDescription: "content size cannot be negative, got \(size)")
        }

        self.digest = digest
        self.size = size
        self.mediaType = try container.decode(String.self, forKey: .mediaType)
        self.urls = try container.decodeIfPresent([String].self, forKey: .urls)
        self.annotations = try container.decodeIfPresent([String: String].self, forKey: .annotations)
        self.platform = try container.decodeIfPresent(Platform.self, forKey: .platform)
        self.artifactType = try container.decodeIfPresent(String.self, forKey: .artifactType)
    }
}
