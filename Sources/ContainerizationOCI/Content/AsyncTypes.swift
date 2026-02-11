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

package actor AsyncStore<T> {
    private var _value: T?

    package init(_ value: T? = nil) {
        self._value = value
    }

    package func get() -> T? {
        self._value
    }

    package func set(_ value: T) {
        self._value = value
    }
}

package actor AsyncSet<T: Hashable> {
    private var buffer: Set<T>

    package init<S: Sequence>(_ elements: S) where S.Element == T {
        buffer = Set(elements)
    }

    package var count: Int {
        buffer.count
    }

    package func insert(_ element: T) {
        buffer.insert(element)
    }

    @discardableResult
    package func remove(_ element: T) -> T? {
        buffer.remove(element)
    }

    package func contains(_ element: T) -> Bool {
        buffer.contains(element)
    }
}
