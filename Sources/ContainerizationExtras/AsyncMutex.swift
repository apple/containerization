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

/// `AsyncMutex` provides a mutex that protects a piece of data, with the main benefit being that it
/// is safe to call async methods while holding the lock. This is primarily used in spots
/// where an actor makes sense, but we may need to ensure we don't fall victim to actor
/// reentrancy issues.
public actor AsyncMutex<T: Sendable> {
    private final class Box: @unchecked Sendable {
        var value: T
        init(_ value: T) {
            self.value = value
        }
    }

    private var busy = false
    private var queue: ArraySlice<CheckedContinuation<(), Never>> = []
    private let box: Box

    public init(_ initialValue: T) {
        self.box = Box(initialValue)
    }

    /// withLock provides a scoped locking API to run a function while holding the lock.
    /// The protected value is passed to the closure for safe access.
    public func withLock<R: Sendable>(_ body: @Sendable @escaping (inout T) async throws -> R) async rethrows -> R {
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

        return try await body(&self.box.value)
    }
}
