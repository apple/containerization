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

import ContainerizationError
import Crypto
import Foundation

extension Mount {
    /// A deterministic hash of the mount's source path, used as the virtiofs tag.
    ///
    /// Resolves symlinks before hashing so that different paths to the same
    /// directory produce an identical tag.
    public var tagHash: String {
        get throws {
            try hashFilePath(path: self.source)
        }
    }
}

func hashFilePath(path: String) throws -> String {
    // Resolve symlinks so different paths to the same directory get the same hash.
    let resolvedSource = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    guard let data = resolvedSource.data(using: .utf8) else {
        throw ContainerizationError(.invalidArgument, message: "\(path) could not be converted to Data")
    }
    return String(SHA256.hash(data: data).encoded.prefix(36))
}
