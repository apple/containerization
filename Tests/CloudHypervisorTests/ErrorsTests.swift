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
import NIOHTTP1
import Testing

@testable import CloudHypervisor

@Suite("CloudHypervisor.Error")
struct ErrorsTests {
    @Test("http case carries status and body")
    func httpCase() {
        let err = CloudHypervisor.Error.http(status: .badRequest, body: Data("nope".utf8))
        guard case .http(let status, let body) = err else {
            Issue.record("expected .http")
            return
        }
        #expect(status == .badRequest)
        #expect(String(data: body, encoding: .utf8) == "nope")
    }
}
