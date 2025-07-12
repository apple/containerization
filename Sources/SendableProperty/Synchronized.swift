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

// `Synchronization` will be automatically imported with `SendableProperty`.
@_exported import Synchronization

/// A synchronization primitive that protects shared mutable state via mutual exclusion.
public final class Synchronized<T>: Sendable {
    private let lock: Mutex<State>

    private struct State: @unchecked Sendable {
        var value: T
    }

    /// Creates a new instance.
    /// - Parameter value: The initial value.
    public init(_ value: T) {
        self.lock = Mutex(State(value: value))
    }

    /// Calls the given closure after acquiring the lock and returns its value.
    /// - Parameter body: The body of code to execute while the lock is held.
    public func withLock<R>(_ body: (inout T) throws -> R) rethrows -> R {
        try lock.withLock { state in
            try body(&state.value)
        }
    }
}
