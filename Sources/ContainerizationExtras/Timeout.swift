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

/// `Timeout` contains helpers to run an operation and error out if
/// the operation does not finish within a provided time.
public struct Timeout {
    /// Performs the passed in `operation` and throws a `CancellationError` if the operation
    /// doesn't finish in the provided `seconds` amount.
    public static func run<T: Sendable>(
        seconds: UInt32,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }

            guard let result = try await group.next() else {
                fatalError()
            }

            group.cancelAll()
            return result
        }
    }

    public static func run<T: Sendable>(
        for duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: duration)
                throw CancellationError()
            }

            guard let result = try await group.next() else {
                fatalError()
            }

            group.cancelAll()
            return result
        }
    }
}
