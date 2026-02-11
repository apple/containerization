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
import Testing

@testable import ContainerizationExtras

final class AsyncMutexTests {
    @Test
    func testBasicModification() async throws {
        let mutex = AsyncMutex(0)

        let result = await mutex.withLock { value in
            value += 1
            return value
        }

        #expect(result == 1)
    }

    @Test
    func testMultipleModifications() async throws {
        let mutex = AsyncMutex(0)

        await mutex.withLock { value in
            value += 5
        }

        let result = await mutex.withLock { value in
            value += 10
            return value
        }

        #expect(result == 15)
    }

    @Test
    func testConcurrentAccess() async throws {
        let mutex = AsyncMutex(0)
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await mutex.withLock { value in
                        value += 1
                    }
                }
            }
        }

        let finalValue = await mutex.withLock { value in
            value
        }

        #expect(finalValue == iterations)
    }

    @Test
    func testAsyncOperationsUnderLock() async throws {
        let mutex = AsyncMutex([Int]())

        await mutex.withLock { value in
            try? await Task.sleep(for: .milliseconds(10))
            value.append(1)
        }

        await mutex.withLock { value in
            try? await Task.sleep(for: .milliseconds(10))
            value.append(2)
        }

        let result = await mutex.withLock { value in
            value
        }

        #expect(result == [1, 2])
    }

    @Test
    func testThrowingClosure() async throws {
        let mutex = AsyncMutex(0)

        await #expect(throws: POSIXError.self) {
            try await mutex.withLock { value in
                value += 1
                throw POSIXError(.ENOENT)
            }
        }

        // Value should still be modified even though closure threw
        let result = await mutex.withLock { value in
            value
        }

        #expect(result == 1)
    }

    @Test
    func testComplexDataStructure() async throws {
        struct Counter: Sendable {
            var count: Int
            var label: String
        }

        let mutex = AsyncMutex(Counter(count: 0, label: "test"))

        await mutex.withLock { value in
            value.count += 10
            value.label = "modified"
        }

        await mutex.withLock { value in
            #expect(value.count == 10)
            #expect(value.label == "modified")
        }
    }
}
