//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging

extension IntegrationSuite {
    func testMounts() async throws {
        let id = "test-cat-mount"

        let bs = try await bootstrap()
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        let directory = try createMountDirectory()
        container.mounts.append(.share(source: directory.path, destination: "/mnt"))
        container.arguments = ["/bin/cat", "/mnt/hi.txt"]

        let buffer = BufferWriter()
        container.stdout = buffer

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        let value = String(data: buffer.data, encoding: .utf8)
        guard value == "hello" else {
            throw IntegrationError.assert(
                msg: "process should have returned from file 'hello' != '\(String(data: buffer.data, encoding: .utf8)!)")

        }
    }

    func testNestedVirtualizationEnabled() async throws {
        let id = "test-nested-virt"

        let bs = try await bootstrap()
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/bin/true"]

        container.virtualization = true

        do {
            try await container.create()
            try await container.start()
        } catch {
            if let err = error as? ContainerizationError {
                if err.code == .unsupported {
                    throw SkipTest(reason: err.message)
                }
            }
        }

        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
    }

    private func createMountDirectory() throws -> URL {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        try "hello".write(to: dir.appendingPathComponent("hi.txt"), atomically: true, encoding: .utf8)
        return dir
    }
}
