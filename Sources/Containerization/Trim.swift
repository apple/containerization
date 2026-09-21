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

import Logging

/// A filesystem path and the mount namespace in which to resolve it.
public enum TrimTarget: Sendable, Hashable {
    /// A runtime-owned mount, including overlay backing layers hidden by pivot_root.
    /// Requires the mount to exist, but no running container process.
    case sandbox(path: String)
    /// A path visible to a running container, including its block mounts.
    case container(id: String, path: String)

    public var path: String {
        switch self {
        case .sandbox(let path), .container(_, let path): path
        }
    }
}

extension VirtualMachineInstance {
    /// Trim distinct targets sequentially to limit I/O contention, returning the
    /// total filesystem-reported discard bytes. Empty sweeps need no agent connection.
    ///
    /// Runtime-selected sweeps skip ``FilesystemCannotDiscard`` because mount configuration
    /// cannot establish discard support. Explicit targets propagate that error.
    func trim(
        _ targets: [TrimTarget],
        skippingWhatCannotDiscard: Bool,
        logger: Logger?
    ) async throws -> UInt64 {
        guard !targets.isEmpty else {
            return 0
        }
        return try await self.withAgent { agent in
            var trimmed: UInt64 = 0
            var seen: Set<TrimTarget> = []
            for target in targets where seen.insert(target).inserted {
                try Task.checkCancellation()
                do {
                    trimmed += try await agent.trimFilesystem(target)
                } catch let error as FilesystemCannotDiscard where skippingWhatCannotDiscard {
                    logger?.debug("nothing to trim at \(error)")
                }
            }
            return trimmed
        }
    }
}
