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

import Containerization

extension LinuxContainer {
    /// Run a shell script in the container and require it to succeed.
    func sh(_ id: String, script: String) async throws {
        try await self.run(id, script: script, stdout: nil)
    }

    /// Run a shell script in the container, require it to succeed, and return what
    /// it wrote to stdout.
    func output(_ id: String, script: String) async throws -> String {
        let buffer = IntegrationSuite.BufferWriter()
        try await self.run(id, script: script, stdout: buffer)
        return String(decoding: buffer.data, as: UTF8.self)
    }

    private func run(_ id: String, script: String, stdout: Writer?) async throws {
        let process = try await self.exec(id) { config in
            config.arguments = ["/bin/sh", "-c", script]
            config.stdout = stdout
        }
        try await process.start()
        let status = try await process.wait()
        try await process.delete()
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "\(id) exited \(status.exitCode)")
        }
    }
}

extension LinuxPod {
    /// Run a shell script in one of the pod's containers and require it to succeed.
    func sh(_ containerID: String, processID: String, script: String) async throws {
        let process = try await self.execInContainer(containerID, processID: processID) {
            $0.arguments = ["/bin/sh", "-c", script]
        }
        try await process.start()
        let status = try await process.wait()
        try await process.delete()
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "\(processID) exited \(status.exitCode)")
        }
    }
}
