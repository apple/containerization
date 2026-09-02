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

#if os(macOS)
extension IntegrationSuite {

    /// Image used by the `cctl run` command-resolution tests. It declares no
    /// ENTRYPOINT and `CMD ["/bin/sh"]`, which is what makes the default-command
    /// case observable.
    static let cctlRunImage = "docker.io/library/alpine:3.16"

    /// With no trailing command, `cctl run` runs the image's ENTRYPOINT + CMD.
    ///
    /// The alpine test image declares no ENTRYPOINT and `CMD ["/bin/sh"]`, so a
    /// bare `cctl run` should land in a shell. Feeding a command on stdin proves
    /// it really is a shell rather than something that merely exited cleanly.
    func testCctlRunUsesImageDefaultCommand() async throws {
        let marker = "DEFAULT_CMD_RAN"
        let (output, exitCode) = try runCctl(
            arguments: [
                "run", "--kernel", self.kernel, "--id", "test-cctl-run-default-cmd",
                "-i", Self.cctlRunImage,
            ],
            input: "echo \(marker)\nexit\n"
        )

        guard exitCode == 0 else {
            throw IntegrationError.assert(msg: "cctl run exited with \(exitCode): \(output)")
        }
        guard output.contains(marker) else {
            throw IntegrationError.assert(msg: "expected the image's CMD shell to run, got: \(output)")
        }
    }

    /// A trailing command replaces the image's CMD.
    func testCctlRunExplicitCommandOverridesDefault() async throws {
        let marker = "EXPLICIT_COMMAND_RAN"
        let (output, exitCode) = try runCctl(arguments: [
            "run", "--kernel", self.kernel, "--id", "test-cctl-run-explicit-command",
            "-i", Self.cctlRunImage,
            "/bin/echo", marker,
        ])

        guard exitCode == 0 else {
            throw IntegrationError.assert(msg: "cctl run exited with \(exitCode): \(output)")
        }
        guard output.contains(marker) else {
            throw IntegrationError.assert(msg: "expected the explicit command to run, got: \(output)")
        }
    }

    /// An image declaring neither ENTRYPOINT nor CMD has nothing to run, so a
    /// bare `cctl run` must say so rather than falling back to a hardcoded
    /// shell. `vminit:latest` is built by `cctl rootfs create`, which sets only
    /// labels on the image config — no command of any kind.
    ///
    /// This is the case that cannot pass under the old behaviour, where the
    /// command defaulted to `/bin/sh` regardless of the image.
    func testCctlRunWithoutEntrypointOrCmdFails() async throws {
        let (output, exitCode) = try runCctl(arguments: [
            "run", "--kernel", self.kernel, "--id", "test-cctl-run-no-command",
            "-i", Self.initImage,
        ])

        guard exitCode != 0 else {
            throw IntegrationError.assert(msg: "expected a failure for an image with no entrypoint or cmd: \(output)")
        }
        guard output.contains("declares no entrypoint or cmd") else {
            throw IntegrationError.assert(msg: "expected an entrypoint/cmd error, got: \(output)")
        }
    }
}
#endif
