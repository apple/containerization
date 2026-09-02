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

import ContainerizationOCI
import Foundation
import Testing

@testable import cctl

/// `cctl run` resolves the container command as `ENTRYPOINT + (arguments ?? CMD)`.
/// Trailing arguments replace CMD but are appended to ENTRYPOINT
@Suite("cctl run command resolution")
struct RunArgumentsTests {

    /// One scenario. A nil `expected` means the resolution must fail.
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let imageConfig: ImageConfig?
        let arguments: [String]
        let expected: [String]?

        var testDescription: String { name }
    }

    private static let cases: [Case] = [
        // Entrypoint and cmd both present.
        .init(
            name: "no arguments uses entrypoint and cmd",
            imageConfig: ImageConfig(entrypoint: ["/bin/echo"], cmd: ["default"]),
            arguments: [],
            expected: ["/bin/echo", "default"]
        ),
        .init(
            name: "arguments replace cmd but keep entrypoint",
            imageConfig: ImageConfig(entrypoint: ["/bin/echo"], cmd: ["default"]),
            arguments: ["override"],
            expected: ["/bin/echo", "override"]
        ),
        // The regression that motivated this rule: replacing the whole command left
        // the guest trying to exec `--nbd-url`.
        .init(
            name: "flag-shaped arguments append to entrypoint",
            imageConfig: ImageConfig(entrypoint: ["/usr/local/bin/format-volume"], cmd: ["default"]),
            arguments: ["--nbd-url", "nbd://h:1/v", "--filesystem", "xfs"],
            expected: ["/usr/local/bin/format-volume", "--nbd-url", "nbd://h:1/v", "--filesystem", "xfs"]
        ),
        .init(
            name: "multi-word entrypoint is preserved in order",
            imageConfig: ImageConfig(entrypoint: ["/bin/sh", "-c"], cmd: ["y"]),
            arguments: ["x"],
            expected: ["/bin/sh", "-c", "x"]
        ),

        // Only one of entrypoint / cmd.
        .init(
            name: "entrypoint only with no arguments",
            imageConfig: ImageConfig(entrypoint: ["/bin/true"]),
            arguments: [],
            expected: ["/bin/true"]
        ),
        .init(
            name: "entrypoint only with arguments",
            imageConfig: ImageConfig(entrypoint: ["/bin/true"]),
            arguments: ["--flag"],
            expected: ["/bin/true", "--flag"]
        ),
        .init(
            name: "cmd only with no arguments",
            imageConfig: ImageConfig(cmd: ["/bin/sh"]),
            arguments: [],
            expected: ["/bin/sh"]
        ),
        // With no entrypoint the arguments are the whole command, so CMD is dropped.
        .init(
            name: "cmd only with arguments replaces cmd entirely",
            imageConfig: ImageConfig(cmd: ["/bin/sh"]),
            arguments: ["/bin/echo", "hi"],
            expected: ["/bin/echo", "hi"]
        ),

        // Nothing declared by the image, but the caller supplied the command outright.
        .init(
            name: "no entrypoint or cmd but arguments given",
            imageConfig: ImageConfig(),
            arguments: ["/bin/echo", "hi"],
            expected: ["/bin/echo", "hi"]
        ),
        .init(
            name: "missing image config with arguments",
            imageConfig: nil,
            arguments: ["/bin/echo"],
            expected: ["/bin/echo"]
        ),
        // Explicitly empty arrays must behave exactly like absent ones.
        .init(
            name: "empty arrays with arguments behave as absent",
            imageConfig: ImageConfig(entrypoint: [], cmd: []),
            arguments: ["/bin/echo"],
            expected: ["/bin/echo"]
        ),

        // Nothing to run.
        .init(
            name: "no entrypoint, no cmd, no arguments fails",
            imageConfig: ImageConfig(),
            arguments: [],
            expected: nil
        ),
        .init(
            name: "missing image config and no arguments fails",
            imageConfig: nil,
            arguments: [],
            expected: nil
        ),
        .init(
            name: "empty arrays with no arguments fails",
            imageConfig: ImageConfig(entrypoint: [], cmd: []),
            arguments: [],
            expected: nil
        ),
    ]

    @Test("resolves", arguments: cases)
    func resolves(_ testCase: Case) throws {
        let resolve = {
            try Application.resolveProcessArguments(
                arguments: testCase.arguments,
                imageConfig: testCase.imageConfig,
                imageReference: "test:latest"
            )
        }

        guard let expected = testCase.expected else {
            #expect(throws: (any Error).self) { try resolve() }
            return
        }

        let resolved = try resolve()
        #expect(resolved == expected)
    }

    @Test func errorNamesTheOffendingImage() {
        do {
            _ = try Application.resolveProcessArguments(
                arguments: [],
                imageConfig: ImageConfig(),
                imageReference: "registry.example/thing:v2"
            )
            Issue.record("expected a failure for an image with no entrypoint or cmd")
        } catch {
            #expect("\(error)".contains("registry.example/thing:v2"))
        }
    }
}
