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

import Foundation
import Testing

@testable import ContainerizationExtras

private final class Unprotected: @unchecked Sendable {
    var value: Int
    init(_ value: Int) { self.value = value }
}

final class AsyncLockTests {
    @Test
    func testBasicModification() async throws {
        let lock = AsyncLock()
        let counter = Unprotected(0)

        let result = await lock.withLock { _ in
            counter.value += 1
            return counter.value
        }

        #expect(result == 1)
    }

    @Test
    func testSequentialReturnValues() async throws {
        let lock = AsyncLock()

        let first = await lock.withLock { _ in 1 }
        let second = await lock.withLock { _ in first + 1 }
        let third = await lock.withLock { _ in second + 1 }

        #expect(third == 3)
    }

    @Test
    func testMultipleModifications() async throws {
        let lock = AsyncLock()
        let counter = Unprotected(0)

        await lock.withLock { _ in
            counter.value += 5
        }

        let result = await lock.withLock { value in
            counter.value += 10
            return counter.value
        }

        #expect(result == 15)
    }

    @Test
    func testMutualExclusion() async throws {
        let lock = AsyncLock()
        let counter = Unprotected(0)
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await lock.withLock { _ in
                        let current = counter.value
                        try? await Task.sleep(for: .milliseconds(10))
                        counter.value = current + 1
                    }
                }
            }
        }

        #expect(counter.value == iterations)
    }

    @Test
    func testThrowingClosure() async throws {
        let lock = AsyncLock()
        let counter = Unprotected(0)

        await #expect(throws: POSIXError.self) {
            try await lock.withLock { _ in
                counter.value = 1
                throw POSIXError(.ENOENT)
            }
        }

        // Value should still be modified even though closure threw
        #expect(counter.value == 1)

        // Lock should still be usable even though the previous closure threw
        await lock.withLock { _ in
            counter.value = 2
        }

        #expect(counter.value == 2)
    }
}
