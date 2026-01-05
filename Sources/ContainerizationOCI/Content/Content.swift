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

import ContainerizationExtras
import Crypto
import Foundation
import NIOCore

/// Protocol for defining a single OCI content
public protocol Content: Sendable {
    /// URL to the content
    var path: URL { get }

    /// sha256 of content
    func digest() throws -> SHA256.Digest

    /// Size of content
    func size() throws -> UInt64

    /// Data representation of entire content
    func data() throws -> Data

    /// Data representation partial content
    func data(offset: UInt64, length: Int) throws -> Data?

    /// Decode the content into an object
    func decode<T>() throws -> T where T: Decodable
}

/// Protocol defining methods to fetch and push OCI content
public protocol ContentClient: Sendable {
    func fetch<T: Codable>(name: String, descriptor: Descriptor) async throws -> T

    func fetchBlob(name: String, descriptor: Descriptor, into file: URL, progress: ProgressHandler?) async throws -> (Int64, SHA256Digest)

    func fetchData(name: String, descriptor: Descriptor) async throws -> Data

    func push<T: Sendable & AsyncSequence>(
        name: String,
        ref: String,
        descriptor: Descriptor,
        streamGenerator: () throws -> T,
        progress: ProgressHandler?
    ) async throws where T.Element == ByteBuffer

}
