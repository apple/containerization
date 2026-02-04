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
import ContainerizationOCI
import Foundation

/// The `Unpacker` protocol defines a standardized interface that involves
/// decompressing, extracting image layers and preparing it for use.
///
/// The `Unpacker` is responsible for managing the lifecycle of the
/// unpacking process, including any temporary files or resources, until the
/// `Mount` object is produced.
public protocol Unpacker {

    /// Unpacks the provided image to a specified path for a given platform.
    ///
    /// This asynchronous method should handle the entire unpacking process, from reading
    /// the `Image` layers for the given `Platform` via its `Manifest`,
    /// to making the extracted contents available as a `Mount`.
    /// Implementations of this method may apply platform-specific optimizations
    /// or transformations during the unpacking.
    ///
    /// Progress updates can be observed via the optional `progress` handler.
    func unpack(_ image: Image, for platform: Platform, at path: URL, progress: ProgressHandler?) async throws -> Mount

}
