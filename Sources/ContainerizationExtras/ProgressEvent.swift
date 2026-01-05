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

/// A progress update event.
public struct ProgressEvent: Sendable {
    /// The event name. The possible values:
    ///  - `add-items`: Increment the number of processed items by `value`.
    ///  - `add-total-items`: Increment the total number of items to process by `value`.
    ///  - `add-size`: Increment the size of processed items by `value`.
    ///  - `add-total-size`: Increment the total size of items to process by `value`.
    public let event: String
    /// The event value.
    public let value: any Sendable

    /// Creates an instance.
    /// - Parameters:
    ///   - event: The event name.
    ///   - value: The event value.
    public init(event: String, value: any Sendable) {
        self.event = event
        self.value = value
    }
}

/// The progress update handler.
public typealias ProgressHandler = @Sendable (_ events: [ProgressEvent]) async -> Void
