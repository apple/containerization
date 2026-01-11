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

import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

extension Application {
    static func fetchImage(reference: String, store: ImageStore) async throws -> Containerization.Image {
        do {
            return try await store.get(reference: reference)
        } catch let error as ContainerizationError {
            if error.code == .notFound {
                return try await store.pull(reference: reference)
            }
            throw error
        }
    }

    static func parseKeyValuePairs(from items: [String]) -> [String: String] {
        var parsedLabels: [String: String] = [:]
        for item in items {
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let key = String(parts[0])
            let val = String(parts[1])
            parsedLabels[key] = val
        }
        return parsedLabels
    }
}

extension ContainerizationOCI.Platform {
    static var arm64: ContainerizationOCI.Platform {
        .init(arch: "arm64", os: "linux", variant: "v8")
    }
}
