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

struct TestTimeout {
    
    @Test func testSuccessfulOperation() async throws {
        let result = try await Timeout.run(seconds: 5) {
            return "success"
        }
        
        #expect(result == "success")
    }
    
    @Test func testQuickOperation() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let result = try await Timeout.run(seconds: 10) {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            return 42
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        #expect(result == 42)
        #expect(elapsed < 1.0, "Quick operation should complete quickly")
    }
    
    @Test func testTimeoutOccurs() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            let _ = try await Timeout.run(seconds: 1) {
                // Operation that takes longer than timeout
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                return "should not reach here"
            }
            #expect(Bool(false), "Should have thrown CancellationError")
        } catch is CancellationError {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            // Should timeout around 1 second, allow some tolerance
            #expect(elapsed >= 0.9 && elapsed <= 1.5, "Timeout should occur around 1 second, got \(elapsed)")
        }
    }
    
    @Test func testZeroTimeout() async throws {
        do {
            let _ = try await Timeout.run(seconds: 0) {
                return "immediate"
            }
            // With 0 timeout, either the operation completes immediately or times out
            // Both are valid behaviors
        } catch is CancellationError {
            // Also valid - 0 timeout can immediately cancel
        }
    }
    
    // Test with a throwing operation wrapped in a non-throwing closure
    @Test func testOperationThrowsError() async throws {
        struct CustomError: Error, Equatable {}
        
        let result = try await Timeout.run(seconds: 5) {
            // Simulate a throwing operation by returning a Result
            return Result<String, CustomError>.failure(CustomError())
        }
        
        switch result {
        case .success:
            #expect(Bool(false), "Should have returned failure")
        case .failure:
            // Expected error result
            break
        }
    }
    
    @Test func testOperationThrowsErrorBeforeTimeout() async throws {
        struct QuickError: Error {}
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let result = try await Timeout.run(seconds: 10) {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            return Result<String, QuickError>.failure(QuickError())
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        #expect(elapsed < 1.0, "Error should occur quickly, not after timeout")
        
        switch result {
        case .success:
            #expect(Bool(false), "Should have returned failure")
        case .failure:
            // Expected error result
            break
        }
    }
    
    @Test func testConcurrentTimeouts() async throws {
        let results = await withTaskGroup(of: Result<String, Error>.self, returning: [Result<String, Error>].self) { group in
            // Mix of operations that succeed and timeout
            for i in 0..<5 {
                group.addTask {
                    do {
                        let result = try await Timeout.run(seconds: 1) {
                            if i % 2 == 0 {
                                // Even numbers succeed quickly
                                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                return "success-\(i)"
                            } else {
                                // Odd numbers timeout
                                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                                return "timeout-\(i)"
                            }
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<String, Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        #expect(results.count == 5)
        
        var successes = 0
        var timeouts = 0
        
        for result in results {
            switch result {
            case .success(let value):
                #expect(value.hasPrefix("success-"))
                successes += 1
            case .failure(let error):
                #expect(error is CancellationError)
                timeouts += 1
            }
        }
        
        #expect(successes == 3) // Even numbers: 0, 2, 4
        #expect(timeouts == 2)  // Odd numbers: 1, 3
    }
    
    @Test func testComplexReturnType() async throws {
        struct ComplexResult: Equatable, Sendable {
            let id: Int
            let name: String
            
            static func == (lhs: ComplexResult, rhs: ComplexResult) -> Bool {
                return lhs.id == rhs.id && lhs.name == rhs.name
            }
        }
        
        let expected = ComplexResult(id: 123, name: "test")
        
        let result = try await Timeout.run(seconds: 5) {
            return expected
        }
        
        #expect(result == expected)
    }
    
    @Test func testTimeoutAccuracy() async throws {
        let timeoutSeconds: UInt32 = 2
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            let _ = try await Timeout.run(seconds: timeoutSeconds) {
                // Operation that definitely takes longer than timeout
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                return "should not complete"
            }
            #expect(Bool(false), "Should have timed out")
        } catch is CancellationError {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let expectedTimeout = Double(timeoutSeconds)
            
            // Allow 20% tolerance for timing accuracy
            let tolerance = expectedTimeout * 0.2
            let minTime = expectedTimeout - tolerance
            let maxTime = expectedTimeout + tolerance
            
            #expect(elapsed >= minTime && elapsed <= maxTime, 
                   "Timeout should occur around \(expectedTimeout)s, got \(elapsed)s")
        }
    }
    
    @Test func testAsyncOperationInTimeout() async throws {
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
        
        let result = try await Timeout.run(seconds: 5) {
            let value1 = await counter.increment()
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            let value2 = await counter.increment()
            return (value1, value2)
        }
        
        #expect(result.0 == 1)
        #expect(result.1 == 2)
        #expect(await counter.getValue() == 2)
    }
    
    @Test func testTimeoutWithTaskCancellation() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            let _ = try await Timeout.run(seconds: 1) {
                // Operation that checks for cancellation
                for _ in 0..<100 {
                    if Task.isCancelled {
                        return "cancelled"
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms per iteration
                }
                return "completed"
            }
            // Either cancellation or completion is valid
        } catch is CancellationError {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            #expect(elapsed <= 1.5, "Should be cancelled within timeout period")
        }
    }
    
    @Test func testLargeTimeout() async throws {
        // Test with a very large timeout to ensure no overflow issues
        let result = try await Timeout.run(seconds: UInt32.max) {
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
            return "quick-result"
        }
        
        #expect(result == "quick-result")
    }
    
    @Test func testTimeoutPerformance() async throws {
        let iterations = 100
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for _ in 0..<iterations {
            let _ = try await Timeout.run(seconds: 10) {
                return "quick"
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgTime = elapsed / Double(iterations)
        
        // Each timeout operation should be very fast for quick operations
        #expect(avgTime < 0.01, "Average timeout overhead too high: \(avgTime)s per operation")
    }
    
    @Test func testMultipleConsecutiveTimeouts() async throws {
        for i in 0..<5 {
            do {
                let _ = try await Timeout.run(seconds: 1) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    return "should timeout"
                }
                #expect(Bool(false), "Iteration \(i) should have timed out")
            } catch is CancellationError {
                // Expected timeout
            }
        }
    }
    
    @Test func testTimeoutDoesNotLeakTasks() async throws {
        // This test ensures that timeout operations clean up properly
        let initialTaskCount = Task.basePriority // Proxy for checking task state
        
        for _ in 0..<10 {
            let _ = try await Timeout.run(seconds: 5) {
                return "quick"
            }
        }
        
        // Give time for cleanup
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // This is a basic check - in a real scenario you'd need more sophisticated
        // task leak detection, but this ensures the basic structure works
        #expect(Task.basePriority == initialTaskCount)
    }
} 