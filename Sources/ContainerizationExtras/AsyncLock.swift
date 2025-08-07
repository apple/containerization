//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

/// An async-safe mutual exclusion lock for coordinating access to shared resources.
///
/// `AsyncLock` provides a familiar locking API with the key benefit that it's safe to call
/// async methods while holding the lock. This addresses scenarios where traditional actors
/// might suffer from reentrancy issues or where you need explicit sequential access control.
///
/// ## Use Cases
/// - Protecting shared mutable state that requires async operations
/// - Coordinating access to resources that don't support concurrent operations
/// - Avoiding actor reentrancy issues in complex async workflows
/// - Ensuring sequential execution of async operations
///
/// ## Example usage:
/// ```swift
/// actor ResourceManager {
///     private let lock = AsyncLock()
///     private var resources: [String] = []
///
///     func addResource(_ name: String) async {
///         await lock.withLock { context in
///             // Async operations are safe within the lock
///             let processedName = await processResourceName(name)
///             resources.append(processedName)
///             await notifyObservers(about: processedName)
///         }
///     }
///
///     func getResourceCount() async -> Int {
///         await lock.withLock { context in
///             return resources.count
///         }
///     }
/// }
/// ```
///
/// ## Threading Safety
/// This lock is designed for use within actors or other async contexts and provides
/// mutual exclusion without blocking threads. Operations are queued and resumed
/// sequentially as the lock becomes available.
public actor AsyncLock {
    private var busy = false
    private var queue: ArraySlice<CheckedContinuation<(), Never>> = []

    /// A context object provided to closures executed within the lock.
    ///
    /// The context serves as proof that the code is executing within the lock's
    /// critical section. While currently empty, it may be extended in the future
    /// to provide lock-specific functionality.
    public struct Context: Sendable {
        fileprivate init() {}
    }

    /// Creates a new AsyncLock instance.
    ///
    /// The lock starts in an unlocked state and is ready for immediate use.
    public init() {}

    /// Executes a closure while holding the lock, ensuring exclusive access.
    ///
    /// - Parameter body: An async closure to execute while holding the lock.
    ///                  The closure receives a `Context` parameter as proof of lock ownership.
    /// - Returns: The value returned by the closure
    /// - Throws: Any error thrown by the closure
    ///
    /// This method provides scoped locking - the lock is automatically acquired before
    /// the closure executes and released when the closure completes (either normally
    /// or by throwing an error).
    ///
    /// If the lock is already held, the current operation will suspend until the lock
    /// becomes available. Operations are queued and executed in FIFO order.
    ///
    /// ## Example:
    /// ```swift
    /// let lock = AsyncLock()
    /// var counter = 0
    ///
    /// // Safely increment counter with async work
    /// let result = await lock.withLock { context in
    ///     let oldValue = counter
    ///     await Task.sleep(nanoseconds: 1_000_000) // Simulate async work
    ///     counter = oldValue + 1
    ///     return counter
    /// }
    /// ```
    ///
    /// ## Performance Notes
    /// - The lock uses actor isolation, so there's no thread blocking
    /// - Suspended operations consume minimal memory
    /// - Lock contention is resolved in first-in-first-out order
    public func withLock<T: Sendable>(_ body: @Sendable @escaping (Context) async throws -> T) async rethrows -> T {
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

        let context = Context()
        return try await body(context)
    }
}
