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

/// Provides utilities for executing async operations with time constraints.
///
/// `Timeout` helps ensure that long-running async operations don't hang indefinitely
/// by automatically canceling them after a specified duration. This is especially
/// useful for network operations, file I/O, or any async task that might block.
///
/// ## Use Cases
/// - Network requests that might hang
/// - File operations on potentially slow storage
/// - Container or VM operations with unpredictable execution times
/// - Any async operation that needs guaranteed completion time
///
/// ## Example usage:
/// ```swift
/// // Timeout a network request after 30 seconds
/// do {
///     let data = try await Timeout.run(seconds: 30) {
///         await networkClient.fetchData()
///     }
///     print("Request completed: \(data)")
/// } catch is CancellationError {
///     print("Request timed out after 30 seconds")
/// }
///
/// // Timeout a container start operation
/// do {
///     let container = try await Timeout.run(seconds: 60) {
///         await containerManager.startContainer(id: "abc123")
///     }
///     print("Container started successfully")
/// } catch is CancellationError {
///     print("Container start timed out")
/// }
/// ```
public struct Timeout {
    /// Executes an async operation with a timeout, canceling it if it doesn't complete in time.
    ///
    /// - Parameters:
    ///   - seconds: The maximum number of seconds to wait for the operation to complete
    ///   - operation: The async operation to execute with timeout protection
    /// - Returns: The result of the operation if it completes within the timeout
    /// - Throws: `CancellationError` if the operation doesn't complete within the specified time
    ///
    /// This method uses structured concurrency to race the provided operation against
    /// a timer. If the operation completes first, its result is returned. If the timer
    /// expires first, a `CancellationError` is thrown and any pending work is canceled.
    ///
    /// ## Implementation Details
    /// - Uses `TaskGroup` for structured concurrency
    /// - Automatically cancels remaining tasks when one completes
    /// - The timeout precision is limited by the system's task scheduling
    /// - Operations are not forcefully terminated - they receive a cancellation signal
    ///
    /// ## Example:
    /// ```swift
    /// // Simple timeout example
    /// let result = try await Timeout.run(seconds: 5) {
    ///     await someAsyncOperation()
    /// }
    ///
    /// // Handling timeout errors
    /// do {
    ///     let data = try await Timeout.run(seconds: 10) {
    ///         await longRunningOperation()
    ///     }
    ///     handleSuccess(data)
    /// } catch is CancellationError {
    ///     handleTimeout()
    /// } catch {
    ///     handleOtherError(error)
    /// }
    /// ```
    ///
    /// ## Performance Notes
    /// - Minimal overhead when operations complete quickly
    /// - Timer task is automatically cleaned up when operation completes
    /// - Uses cooperative cancellation - operations must check for cancellation
    public static func run<T: Sendable>(
        seconds: UInt32,
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }

            guard let result = try await group.next() else {
                fatalError("TaskGroup.next() unexpectedly returned nil")
            }

            group.cancelAll()
            return result
        }
    }
}
