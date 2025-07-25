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
        
        actor Counter {
            private var value = 0
            
            func increment() -> Int {
                value += 1
                return value
            }
            
            func getValue() -> Int {
                return value
            }
        }
        
        let counter = Counter()
        
        let result = await lock.withLock { context in
            await counter.increment()
        }
        
        #expect(result == 1)
        #expect(await counter.getValue() == 1)
    }
    
    @Test func testSequentialAccess() async throws {
        let lock = AsyncLock()
        
        actor ValueStore {
            private var values: [Int] = []
            
            func append(_ value: Int) {
                values.append(value)
            }
            
            func getValues() -> [Int] {
                return values
            }
        }
        
        let store = ValueStore()
        
        // Execute operations sequentially
        await lock.withLock { context in
            await store.append(1)
        }
        
        await lock.withLock { context in
            await store.append(2)
        }
        
        await lock.withLock { context in
            await store.append(3)
        }
        
        let values = await store.getValues()
        #expect(values == [1, 2, 3])
    }
    
    @Test func testConcurrentAccess() async throws {
        let lock = AsyncLock()
        let expectedCount = 100
        
        actor ValueStore {
            private var values: [Int] = []
            
            func append(_ value: Int) {
                values.append(value)
            }
            
            func getValues() -> [Int] {
                return values
            }
            
            func count() -> Int {
                return values.count
            }
        }
        
        let store = ValueStore()
        
        // Create concurrent tasks that all try to modify the array
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<expectedCount {
                group.addTask {
                    await lock.withLock { context in
                        await store.append(i)
                        // Add small delay to increase chance of race conditions
                        try? await Task.sleep(nanoseconds: 1_000) // 1 microsecond
                    }
                }
            }
            
            await group.waitForAll()
        }
        
        // All values should be present (no race conditions)
        let count = await store.count()
        #expect(count == expectedCount)
        
        // Values should contain all numbers from 0 to expectedCount-1
        let values = await store.getValues()
        let sortedValues = values.sorted()
        #expect(sortedValues == Array(0..<expectedCount))
    }
    
    @Test func testAsyncOperationsInLock() async throws {
        let lock = AsyncLock()
        
        actor ResultStore {
            private var results: [String] = []
            
            func append(_ result: String) {
                results.append(result)
            }
            
            func getResults() -> [String] {
                return results
            }
            
            func count() -> Int {
                return results.count
            }
        }
        
        let store = ResultStore()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    await lock.withLock { context in
                        // Simulate async work
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        await store.append("task-\(i)")
                    }
                }
            }
            
            await group.waitForAll()
        }
        
        let count = await store.count()
        #expect(count == 5)
        
        // Results should all be unique (no concurrent modification)
        let results = await store.getResults()
        #expect(Set(results).count == 5)
    }
    
    @Test func testLockWithThrowingOperation() async throws {
        let lock = AsyncLock()
        
        actor Counter {
            private var value = 0
            
            func increment() -> Int {
                value += 1
                return value
            }
            
            func getValue() -> Int {
                return value
            }
        }
        
        let counter = Counter()
        
        struct TestError: Error {}
        
        do {
            try await lock.withLock { context in
                let _ = await counter.increment()
                throw TestError()
            }
            #expect(Bool(false), "Should have thrown an error")
        } catch is TestError {
            // Expected error
        }
        
        // Lock should still work after an error
        let _ = await lock.withLock { context in
            await counter.increment()
        }
        
        let finalCount = await counter.getValue()
        #expect(finalCount == 2)
    }
    
    @Test func testLockReentrancyPrevention() async throws {
        let lock = AsyncLock()
        
        actor ExecutionTracker {
            private var order: [String] = []
            
            func append(_ event: String) {
                order.append(event)
            }
            
            func getOrder() -> [String] {
                return order
            }
        }
        
        let tracker = ExecutionTracker()
        
        await withTaskGroup(of: Void.self) { group in
            // First task - holds lock for a while
            group.addTask {
                await lock.withLock { context in
                    await tracker.append("task1-start")
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    await tracker.append("task1-end")
                }
            }
            
            // Second task - should wait for first task
            group.addTask {
                // Small delay to ensure task1 starts first
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                await lock.withLock { context in
                    await tracker.append("task2-start")
                    await tracker.append("task2-end")
                }
            }
            
            await group.waitForAll()
        }
        
        // Task 1 should complete entirely before task 2 starts
        let executionOrder = await tracker.getOrder()
        #expect(executionOrder == ["task1-start", "task1-end", "task2-start", "task2-end"])
    }
    
    @Test func testLockFIFOOrdering() async throws {
        let lock = AsyncLock()
        let taskCount = 10
        
        actor ExecutionTracker {
            private var order: [Int] = []
            
            func append(_ value: Int) {
                order.append(value)
            }
            
            func getOrder() -> [Int] {
                return order
            }
        }
        
        let tracker = ExecutionTracker()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    // Small staggered delay to ensure ordering
                    try? await Task.sleep(nanoseconds: UInt64(i * 1_000_000)) // i milliseconds
                    await lock.withLock { context in
                        await tracker.append(i)
                    }
                }
            }
            
            await group.waitForAll()
        }
        
        // Tasks should execute in FIFO order
        let executionOrder = await tracker.getOrder()
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
        
        actor ResultStore {
            private var results: [String] = []
            
            func append(_ result: String) {
                results.append(result)
            }
            
            func getResults() -> [String] {
                return results
            }
            
            func count() -> Int {
                return results.count
            }
        }
        
        let store = ResultStore()
        
        await withTaskGroup(of: Void.self) { group in
            // Task using lock1
            group.addTask {
                await lock1.withLock { context in
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    await store.append("lock1")
                }
            }
            
            // Task using lock2 (should run concurrently with lock1)
            group.addTask {
                await lock2.withLock { context in
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    await store.append("lock2")
                }
            }
            
            await group.waitForAll()
        }
        
        // Both locks should have executed
        let count = await store.count()
        #expect(count == 2)
        
        let results = await store.getResults()
        #expect(Set(results) == Set(["lock1", "lock2"]))
    }
    
    @Test func testContextParameter() async throws {
        let lock = AsyncLock()
        
        await lock.withLock { context in
            // Context should be provided and be the correct type
            _ = context // Just verify it exists and compiles
        }
    }
    
    @Test func testLockPerformance() async throws {
        let lock = AsyncLock()
        let iterations = 1000
        
        actor Counter {
            private var value = 0
            
            func increment() -> Int {
                value += 1
                return value
            }
            
            func getValue() -> Int {
                return value
            }
        }
        
        let counter = Counter()
        let startTime = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    let _ = await lock.withLock { context in
                        await counter.increment()
                    }
                }
            }
            
            await group.waitForAll()
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let finalCount = await counter.getValue()
        
        #expect(finalCount == iterations)
        // Performance check - should complete within reasonable time
        #expect(elapsed < 5.0, "Lock operations took too long: \(elapsed)s")
    }
} 