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
public enum ProgressEvent: Sendable {
    /// The possible values:
    ///  - `add-items`: Increment the number of processed items by `value`.
    ///  - `add-total-items`: Increment the total number of items to process by `value`.
    ///  - `add-size`: Increment the size of processed items by `value`.
    ///  - `add-total-size`: Increment the total size of items to process by `value`.
    case addItems(Int)
    case addTotalItems(Int)
    case addSize(Int64)
    case addTotalSize(Int64)

    /// The event name.
    public var event: String {
        switch self {
        case .addItems: "add-items"
        case .addTotalItems: "add-total-items"
        case .addSize: "add-size"
        case .addTotalSize: "add-total-size"
        }
    }

    /// The event value.
    public var value: any Sendable {
        switch self {
        case .addItems(let value): value
        case .addTotalItems(let value): value
        case .addSize(let value): value
        case .addTotalSize(let value): value
        }
    }
}

/// The progress update handler.
public typealias ProgressHandler = @Sendable (_ events: [ProgressEvent]) async -> Void
