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
import Logging

/// `AsyncLock` provides a familiar locking API, with the main benefit being that it
/// is safe to call async methods while holding the lock. This is primarily used in spots
/// where an actor makes sense, but we may need to ensure we don't fall victim to actor
/// reentrancy issues.
public actor AsyncLock {
    private var busy = false
    private var queue: ArraySlice<CheckedContinuation<(), Never>> = []
    private var log: Logger?

    public struct Context: Sendable {
        fileprivate init() {}
    }

    public init(log: Logger? = nil) {
        self.log = log
    }

    /// withLock provides a scoped locking API to run a function while holding the lock.
    public func withLock<T: Sendable>(logMetadata: Logger.Metadata? = nil, _ body: @Sendable @escaping (Context) async throws -> T) async rethrows -> T {
        log?.debug("acquiring lock", metadata: logMetadata)
        while self.busy {
            await withCheckedContinuation { cc in
                self.queue.append(cc)
            }
        }

        self.busy = true

        defer {
            self.busy = false
            if let next = self.queue.popFirst() {
                next.resume(returning: ())
            } else {
                self.queue = []
            }
        }

        log?.debug("holding lock", metadata: logMetadata)
        defer { log?.debug("releasing lock", metadata: logMetadata) }
        let context = Context()
        return try await body(context)
    }
}
