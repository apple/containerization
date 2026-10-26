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

extension LinuxContainer {
    /// The container-level data stored in a checkpoint directory as `container.json`.
    ///
    /// Alongside it, `state/` holds the virtual machine's saved state bundle.
    public struct Checkpoint: Codable, Sendable, Equatable {
        public static let currentVersion = 1
        public static let manifestName = "container.json"
        public static let stateDirectoryName = "state"

        public var version: Int
        /// The identifier of the container that was checkpointed.
        public var id: String

        public init(id: String) {
            self.version = Self.currentVersion
            self.id = id
        }

        /// Read a checkpoint written by ``save(to:)``.
        public static func load(from url: URL) throws -> Checkpoint {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Checkpoint.self, from: data)
        }

        /// Write the checkpoint to the file at `url` as JSON.
        public func save(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url)
        }
    }
}
