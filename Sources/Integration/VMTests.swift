//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            let directory = try createMountDirectory()
            config.process.arguments = ["/bin/cat", "/mnt/hi.txt"]
            config.mounts.append(.share(source: directory.path, destination: "/mnt"))
            config.process.stdout = buffer
        }

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
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/true"]
            config.virtualization = true
        }

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

    func testContainerManagerCreate() async throws {
        let id = "test-container-manager"

        // Get the kernel from bootstrap
        let bs = try await bootstrap()

        // Create ContainerManager with kernel and initfs reference
        let manager = try ContainerManager(vmm: bs.vmm)
        defer {
            try? manager.delete(id)
        }

        let buffer = BufferWriter()
        let container = try await manager.create(
            id,
            image: bs.image,
            rootfs: bs.rootfs
        ) { config in
            config.process.arguments = ["/bin/echo", "ContainerManager test"]
            config.process.stdout = buffer
        }

        // Start the container
        try await container.create()
        try await container.start()

        // Wait for completion
        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        let output = String(data: buffer.data, encoding: .utf8)
        guard output == "ContainerManager test\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned 'ContainerManager test' != '\(output ?? "nil")'")
        }
    }

    func testContainerReuse() async throws {
        let id = "test-container-reuse"

        // Get the kernel from bootstrap
        let bs = try await bootstrap()

        // Create ContainerManager with kernel and initfs reference
        let manager = try ContainerManager(vmm: bs.vmm)
        defer {
            try? manager.delete(id)
        }

        let buffer = BufferWriter()
        let container = try await manager.create(
            id,
            image: bs.image,
            rootfs: bs.rootfs
        ) { config in
            config.process.arguments = ["/bin/echo", "ContainerManager test"]
            config.process.stdout = buffer
        }

        // Start the container
        try await container.create()
        try await container.start()

        // Wait for completion
        var status = try await container.wait()
        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
        try await container.stop()

        // Recreate things.
        try await container.create()
        try await container.start()

        // Wait for completion.. again.
        status = try await container.wait()
        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        let output = String(data: buffer.data, encoding: .utf8)
        let expected = "ContainerManager test\nContainerManager test\n"
        guard output == expected else {
            throw IntegrationError.assert(
                msg: "process should have returned '\(expected)' != '\(output ?? "nil")'")
        }
    }

    func testContainerDevConsole() async throws {
        let id = "test-container-devconsole"

        let bs = try await bootstrap()

        let manager = try ContainerManager(vmm: bs.vmm)
        defer {
            try? manager.delete(id)
        }

        let buffer = BufferWriter()
        let container = try await manager.create(
            id,
            image: bs.image,
            rootfs: bs.rootfs
        ) { config in
            // We mount devtmpfs by default, and while this includes creating
            // /dev/console typically that'll be pointing to /dev/hvc0 (the
            // virtio serial console). This is just a character device, so a trivial
            // way to check that our bind mounted console setup worked is by just
            // parsing `mount`'s output and looking for /dev/console as it wouldn't
            // be there normally without our dance.
            config.process.arguments = ["mount"]
            config.process.terminal = true
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()
        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard let str = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(
                msg: "failed to convert standard output to a UTF8 string")
        }

        let devConsole = "/dev/console"
        guard str.contains(devConsole) else {
            throw IntegrationError.assert(
                msg: "process should have \(devConsole) in `mount` output")
        }
    }

    private func createMountDirectory() throws -> URL {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        try "hello".write(to: dir.appendingPathComponent("hi.txt"), atomically: true, encoding: .utf8)
        return dir
    }
}
