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

    public init(
        mediaType: String, digest: String, size: Int64, urls: [String]? = nil, annotations: [String: String]? = nil,
        platform: Platform? = nil
    ) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.urls = urls
        self.annotations = annotations
        self.platform = platform
    }
}
