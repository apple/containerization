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

import ContainerizationError
import Foundation

package enum FilesystemOperationPath {
    package static func validate(_ path: String) throws {
        guard path.first == "/", !path.contains("\0") else {
            throw invalidPath(path)
        }
        guard path == "/" || (!path.hasSuffix("/") && !path.contains("//")) else {
            throw invalidPath(path)
        }
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw invalidPath(path)
        }
    }

    private static func invalidPath(_ path: String) -> ContainerizationError {
        ContainerizationError(
            .invalidArgument,
            message: "filesystem operation path must be an absolute canonical container path: \(path.debugDescription)"
        )
    }
}
