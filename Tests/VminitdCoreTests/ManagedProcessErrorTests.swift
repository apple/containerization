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

#if os(Linux)

import ContainerizationError
import Testing

@testable import VminitdCore

@Suite("ManagedProcess vmexec error")
struct ManagedProcessErrorTests {
    @Test func missingExecutableKeepsNotFound() {
        let error = ManagedProcess.vmexecError(
            ContainerizationError(.notFound, message: "failed to find target executable foo").description
        )
        #expect(error.code == .notFound)
        #expect(error.message.contains("failed to find target executable foo"))
    }

    @Test func notExecutableKeepsCode() {
        let error = ManagedProcess.vmexecError(
            ContainerizationError(.notExecutable, message: "failed to exec [/etc/passwd]").description + "\n"
        )
        #expect(error.code == .notExecutable)
    }

    @Test(arguments: [
        ContainerizationError(.internalError, message: "failed to change directory").description,
        ContainerizationError(.invalidArgument, message: "bad").description,
        "unstructured failure",
    ])
    func otherErrorsAreInternal(errorString: String) {
        #expect(ManagedProcess.vmexecError(errorString).code == .internalError)
    }
}

#endif
