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

@Suite("Spec redaction")
struct SpecRedactionTests {
    private static let secret = "hunter2"
    private static let hookSecret = "abc123"

    private func spec() -> Spec {
        Spec(
            hooks: Hooks(
                prestart: [],
                createRuntime: [],
                createContainer: [],
                startContainer: [],
                poststart: [Hook(path: "/hook", args: [], env: ["HOOK_TOKEN=\(Self.hookSecret)"], timeout: nil)],
                poststop: []
            ),
            process: Process(env: ["PATH=/usr/bin", "PASSWORD=\(Self.secret)", "INHERIT_ME"])
        )
    }

    // The property that matters: a whole spec interpolated into a log line
    // must not carry the values, whether or not the author redacted it.
    @Test func interpolatingASpecNeverRendersEnvironmentValues() {
        let rendered = "\(spec())"
        #expect(!rendered.contains(Self.secret))
        #expect(!rendered.contains(Self.hookSecret))
        #expect(rendered.contains("PASSWORD=<redacted>"))
        #expect(rendered.contains("HOOK_TOKEN=<redacted>"))
    }

    // print(), String(describing:) and String(reflecting:) all resolve through
    // description, so none of them is a way around the redaction.
    @Test func everyTextRenderingIsRedacted() {
        let s = spec()
        for rendered in ["\(s)", String(describing: s), String(reflecting: s)] {
            #expect(!rendered.contains(Self.secret))
            #expect(!rendered.contains(Self.hookSecret))
        }
    }

    @Test func variableNamesSurviveSoLogsStayUseful() {
        let rendered = "\(spec())"
        #expect(rendered.contains("PATH="))
        #expect(rendered.contains("PASSWORD="))
    }

    // A bare NAME names a variable to inherit from the parent and carries no
    // value, so there is nothing to hide and it passes through untouched.
    @Test func inheritedEntriesArePreserved() {
        #expect("\(spec())".contains("INHERIT_ME"))
    }

    @Test(arguments: [
        "EMPTY=",
        "CONNECTION=postgres://user:pw@host/db?sslmode=require",
    ])
    func valuesAreMaskedWholeIncludingAnyFurtherEquals(_ entry: String) {
        let name = String(entry[entry.startIndex..<entry.firstIndex(of: "=")!])
        let rendered = "\(Process(env: [entry]))"
        #expect(rendered.contains("\(name)=<redacted>"))
        if let value = entry.split(separator: "=", maxSplits: 1).last, entry.hasSuffix(String(value)), value != name {
            #expect(!rendered.contains(String(value)))
        }
    }

    // Redaction is a rendering concern. Encoding must still produce the real
    // spec, or we would be corrupting what gets written to disk and sent to
    // the guest rather than just cleaning up a log line.
    @Test func encodingIsUnaffected() throws {
        let data = try JSONEncoder().encode(spec())
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(Self.secret))
        #expect(json.contains(Self.hookSecret))

        let decoded = try JSONDecoder().decode(Spec.self, from: data)
        #expect(decoded.process?.env == ["PATH=/usr/bin", "PASSWORD=\(Self.secret)", "INHERIT_ME"])
        #expect(decoded.hooks?.poststart.first?.env == ["HOOK_TOKEN=\(Self.hookSecret)"])
    }

    @Test func theValuesRemainAvailableToCallers() {
        #expect(spec().process?.env.contains("PASSWORD=\(Self.secret)") == true)
    }

    @Test func renderingIsNonMutating() {
        let s = spec()
        _ = "\(s)"
        #expect(s.process?.env == ["PATH=/usr/bin", "PASSWORD=\(Self.secret)", "INHERIT_ME"])
    }

    // Redacting must not cost the log line its other fields, which is the
    // reason description mirrors every field rather than listing a chosen few.
    @Test func theOtherFieldsAreStillRendered() {
        let rendered = "\(Process(args: ["/bin/sh"], cwd: "/work", env: ["A=b"], terminal: true))"
        #expect(rendered.contains("cwd:"))
        #expect(rendered.contains("/work"))
        #expect(rendered.contains("args:"))
        #expect(rendered.contains("/bin/sh"))
        #expect(rendered.contains("terminal:"))
    }
}
