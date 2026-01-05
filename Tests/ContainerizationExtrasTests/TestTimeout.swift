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

final class TestTimeoutType {
    @Test
    func testNoCancellation() async throws {
        await #expect(throws: Never.self) {
            try await Timeout.run(
                for: .seconds(5),
                operation: {
                    return
                })
        }
    }

    @Test
    func testCancellationError() async throws {
        await #expect(throws: CancellationError.self) {
            try await Timeout.run(
                for: .milliseconds(50),
                operation: {
                    try await Task.sleep(for: .seconds(2))
                })
        }
    }

    @Test
    func testClosureError() async throws {
        // Check that we get the closures error if we don't timeout, but
        // the closure does throw before.
        await #expect(throws: POSIXError.self) {
            try await Timeout.run(
                for: .seconds(10),
                operation: {
                    throw POSIXError(.E2BIG)
                })
        }
    }
}
