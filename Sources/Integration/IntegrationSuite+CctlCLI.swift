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

import struct ContainerizationOS.Terminal

#if os(macOS)
extension IntegrationSuite {

    /// Run `bin/cctl run` to completion and return its combined stdout+stderr.
    ///
    /// Exercises the `cctl` CLI rather than the library directly, so it covers
    /// argument parsing and the CLI's own wiring end to end. Shared with the
    /// `--block` tests in PodVolumeTests. `bin/cctl` must be built and
    /// codesigned with the virtualization entitlement.
    ///
    /// - Parameter input: written to the container's stdin, for commands that
    ///   read from it. The pty stays open until the child exits either way.
    func runCctl(arguments: [String], input: String? = nil) throws -> (output: String, exitCode: Int32) {
        let cctl = Self.binPath(name: "cctl")
        guard FileManager.default.isExecutableFile(atPath: cctl.path) else {
            throw IntegrationError.assert(msg: "bin/cctl not built or not executable at \(cctl.path); run `make containerization`")
        }

        let (parent, child) = try Terminal.create()

        let process = Process()
        process.executableURL = cctl
        process.arguments = arguments
        // `cctl run` resolves relative paths (kernel, bin/) against the cwd.
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardInput = child.handle
        process.standardOutput = child.handle
        process.standardError = child.handle

        try process.run()
        // Drop our copy of the child fd. While any process here holds it open
        // the parent side never reports EOF and the drain below never returns.
        try child.close()

        if let input {
            // Written to the pty parent, which the child reads as stdin. Ignore
            // a short write: the drain below reports whatever the child did.
            _ = try? parent.handle.write(contentsOf: Data(input.utf8))
        }

        // Drain before waiting: the pty buffer is far smaller than a pipe's, so
        // a chatty container blocks quickly.
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let parentFD = parent.handle.fileDescriptor
        while true {
            let n = read(parentFD, &buf, buf.count)
            if n > 0 {
                data.append(contentsOf: buf[0..<n])
                continue
            }
            // n == 0 is EOF. n < 0 with EIO is how Darwin reports "last child
            // fd closed" on a pty parent, which is EOF for us too. Retry EINTR.
            if n < 0 && errno == EINTR {
                continue
            }
            break
        }
        process.waitUntilExit()
        try? parent.close()

        // The pty applies ONLCR until cctl switches it to raw mode, so the
        // output is a mix of "\r\n" and "\n". Normalize for callers' matching.
        let output = (String(data: data, encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        return (output, process.terminationStatus)
    }
}
#endif
