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

import Testing
import ContainerizationExtras
import Foundation

struct TestAsyncLock {
    
    @Test func testBasicLocking() async throws {
        let lock = AsyncLock()
        var counter = 0
        
        let result = await lock.withLock { context in
            counter += 1
            return counter
        }
        
        #expect(result == 1)
        #expect(counter == 1)
    }
    
    @Test func testSequentialAccess() async throws {
        let lock = AsyncLock()
        var values: [Int] = []
        
        // Execute operations sequentially
        await lock.withLock { context in
            values.append(1)
        }
        
        await lock.withLock { context in
            values.append(2)
        }
        
        await lock.withLock { context in
            values.append(3)
        }
        
        #expect(values == [1, 2, 3])
    }
    
    @Test func testConcurrentAccess() async throws {
        let lock = AsyncLock()
        var values: [Int] = []
        let expectedCount = 100
        
        // Create concurrent tasks that all try to modify the array
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<expectedCount {
                group.addTask {
                    await lock.withLock { context in
                        values.append(i)
                        // Add small delay to increase chance of race conditions
                        try? await Task.sleep(nanoseconds: 1_000) // 1 microsecond
                    }
                }
            }
            
            await group.waitForAll()
        }
        
        // All values should be present (no race conditions)
        #expect(values.count == expectedCount)
        // Values should contain all numbers from 0 to expectedCount-1
        let sortedValues = values.sorted()
        #expect(sortedValues == Array(0..<expectedCount))
    }
    
    @Test func testAsyncOperationsInLock() async throws {
        let lock = AsyncLock()
        var results: [String] = []
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    await lock.withLock { context in
                        // Simulate async work
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        results.append("task-\(i)")
                    }
                }
            }
            
            await group.waitForAll()
        }
        
        #expect(results.count == 5)
        // Results should all be unique (no concurrent modification)
        #expect(Set(results).count == 5)
    }
    
    @Test func testLockWithThrowingOperation() async throws {
        let lock = AsyncLock()
        var counter = 0
        
        struct TestError: Error {}
        
        do {
            try await lock.withLock { context in
                counter += 1
                throw TestError()
            }
            #expect(Bool(false), "Should have thrown an error")
        } catch is TestError {
            // Expected error
        }
        
        // Lock should still work after an error
        await lock.withLock { context in
            counter += 1
        }
        
        #expect(counter == 2)
    }
    
    @Test func testLockReentrancyPrevention() async throws {
        let lock = AsyncLock()
        var executionOrder: [String] = []
        
        await withTaskGroup(of: Void.self) { group in
            // First task - holds lock for a while
            group.addTask {
                await lock.withLock { context in
                    executionOrder.append("task1-start")
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    executionOrder.append("task1-end")
                }
            }
            
            // Second task - should wait for first task
            group.addTask {
                // Small delay to ensure task1 starts first
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                await lock.withLock { context in
                    executionOrder.append("task2-start")
                    executionOrder.append("task2-end")
                }
            }
            
            await group.waitForAll()
        }
        
        // Task 1 should complete entirely before task 2 starts
        #expect(executionOrder == ["task1-start", "task1-end", "task2-start", "task2-end"])
    }
    
    @Test func testLockFIFOOrdering() async throws {
        let lock = AsyncLock()
        var executionOrder: [Int] = []
        let taskCount = 10
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    // Small staggered delay to ensure ordering
                    try? await Task.sleep(nanoseconds: UInt64(i * 1_000_000)) // i milliseconds
                    await lock.withLock { context in
                        executionOrder.append(i)
                    }
                }
            }
            
            await group.waitForAll()
        }
        
        // Tasks should execute in FIFO order
        #expect(executionOrder == Array(0..<taskCount))
    }
    
    @Test func testLockWithReturnValue() async throws {
        let lock = AsyncLock()
        
        let result = await lock.withLock { context in
            return "test-result"
        }
        
        #expect(result == "test-result")
    }
    
    @Test func testLockWithComplexReturnType() async throws {
        let lock = AsyncLock()
        
        struct ComplexResult: Equatable {
            let id: Int
            let name: String
            let values: [Double]
        }
        
        let expected = ComplexResult(id: 42, name: "test", values: [1.0, 2.5, 3.14])
        
        let result = await lock.withLock { context in
            return expected
        }
        
        #expect(result == expected)
    }
    
    @Test func testMultipleLocks() async throws {
        let lock1 = AsyncLock()
        let lock2 = AsyncLock()
        var results: [String] = []
        
        await withTaskGroup(of: Void.self) { group in
            // Task using lock1
            group.addTask {
                await lock1.withLock { context in
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    results.append("lock1")
                }
            }
            
            // Task using lock2 (should run concurrently with lock1)
            group.addTask {
                await lock2.withLock { context in
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    results.append("lock2")
                }
            }
            
            await group.waitForAll()
        }
        
        // Both locks should have executed
        #expect(results.count == 2)
        #expect(Set(results) == Set(["lock1", "lock2"]))
    }
    
    @Test func testContextParameter() async throws {
        let lock = AsyncLock()
        
        await lock.withLock { context in
            // Context should be provided and be the correct type
            #expect(context is AsyncLock.Context)
        }
    }
    
    @Test func testLockPerformance() async throws {
        let lock = AsyncLock()
        let iterations = 1000
        var counter = 0
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await lock.withLock { context in
                        counter += 1
                    }
                }
            }
            
            await group.waitForAll()
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        #expect(counter == iterations)
        // Performance check - should complete within reasonable time
        #expect(elapsed < 5.0, "Lock operations took too long: \(elapsed)s")
    }
} 