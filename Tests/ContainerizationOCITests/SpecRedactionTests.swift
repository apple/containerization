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

@testable import ContainerizationOCI

struct SpecRedactionTests {
    @Test func processEnvironmentValuesAreRedacted() {
        let process = ContainerizationOCI.Process(
            args: ["python3", "-m", "http.server"],
            cwd: "/app",
            env: [
                "PATH=/usr/local/bin:/usr/bin",
                "MY_SUPER_SECRET_PASSWORD=guest",
                "EMPTY=",
                "TOKEN=abc=def",
                "INHERITED_NO_VALUE",
            ]
        )

        let redacted = process.redactingEnvironmentValues()

        #expect(
            redacted.env == [
                "PATH=<redacted>",
                "MY_SUPER_SECRET_PASSWORD=<redacted>",
                "EMPTY=<redacted>",
                "TOKEN=<redacted>",
                "INHERITED_NO_VALUE",
            ])
        // Everything except env is untouched.
        #expect(redacted.args == process.args)
        #expect(redacted.cwd == process.cwd)
        // The original is not mutated.
        #expect(process.env.contains("MY_SUPER_SECRET_PASSWORD=guest"))
    }

    @Test func redactedProcessRendersWithoutSecretValues() {
        // Mirrors the report in issue #518: interpolating the process into a
        // log message must not expose environment variable values.
        let process = ContainerizationOCI.Process(
            args: ["echo", "hello"],
            env: ["MY_OTHER_SECRET_PASSWORD=abc123"]
        )

        let logged = "\(process.redactingEnvironmentValues())"

        #expect(!logged.contains("abc123"))
        #expect(logged.contains("MY_OTHER_SECRET_PASSWORD"))
    }

    @Test func specRedactsProcessAndHookEnvironments() {
        let hook = Hook(
            path: "/usr/local/bin/hook",
            args: ["hook"],
            env: ["HOOK_SECRET=hunter2"],
            timeout: nil
        )
        let spec = Spec(
            hooks: Hooks(
                prestart: [hook],
                createRuntime: [hook],
                createContainer: [hook],
                startContainer: [hook],
                poststart: [hook],
                poststop: [hook]
            ),
            process: ContainerizationOCI.Process(env: ["MY_SUPER_SECRET_PASSWORD=guest"]),
            hostname: "web",
            mounts: [Mount(type: "proc", source: "proc", destination: "/proc")]
        )

        let redacted = spec.redactingEnvironmentValues()

        let logged = "\(redacted)"
        #expect(!logged.contains("guest"))
        #expect(!logged.contains("hunter2"))
        #expect(logged.contains("MY_SUPER_SECRET_PASSWORD"))
        #expect(logged.contains("HOOK_SECRET"))

        // Everything except environments is untouched.
        #expect(redacted.hostname == spec.hostname)
        #expect(redacted.mounts.count == spec.mounts.count)
        #expect(redacted.process?.env == ["MY_SUPER_SECRET_PASSWORD=<redacted>"])
        #expect(redacted.hooks?.prestart.first?.env == ["HOOK_SECRET=<redacted>"])
        #expect(redacted.hooks?.poststop.first?.env == ["HOOK_SECRET=<redacted>"])
        // The original is not mutated.
        #expect(spec.process?.env == ["MY_SUPER_SECRET_PASSWORD=guest"])
    }

    @Test func specWithoutProcessOrHooksIsUnchanged() {
        let spec = Spec(version: "1.2.0")
        let redacted = spec.redactingEnvironmentValues()
        #expect(redacted.process == nil)
        #expect(redacted.hooks == nil)
        #expect(redacted.version == spec.version)
    }
}
