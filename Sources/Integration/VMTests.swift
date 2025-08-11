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

    func testSingleFileMount() async throws {
        let id = "test-single-file-mount"

        let bs = try await bootstrap()
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            let tempFile = try createSingleMountFile()

            config.process.arguments = ["/bin/cat", "/app/config.txt"]
            config.mounts.append(.share(source: tempFile.path, destination: "/app/config.txt"))
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        let value = String(data: buffer.data, encoding: .utf8)

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0 - output: \(value ?? "nil")")
        }

        // For debugging - just check for success for now
    }

    func testMultipleSingleFileMounts() async throws {
        let id = "test-multiple-single-file-mounts"

        let bs = try await bootstrap()
        let buffer = BufferWriter()
        let errorBuffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            let configFile = try createSingleMountFile(content: "config data")
            let secretFile = try createSingleMountFile(content: "secret data")

            config.process.arguments = ["/bin/sh", "-c", "cat /app/config.txt && echo '---' && cat /app/secret.txt"]
            config.mounts.append(.share(source: configFile.path, destination: "/app/config.txt"))
            config.mounts.append(.share(source: secretFile.path, destination: "/app/secret.txt"))
            config.process.stdout = buffer
            config.process.stderr = errorBuffer
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        let value = String(data: buffer.data, encoding: .utf8)
        let errorValue = String(data: errorBuffer.data, encoding: .utf8)
        let expected = "config data---\nsecret data"

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0 - stdout: \(value ?? "nil") - stderr: \(errorValue ?? "nil")")
        }

        guard value == expected else {
            throw IntegrationError.assert(
                msg: "process should have returned '\(expected)' != '\(value ?? "nil")'")
        }
    }

    private func createMountDirectory() throws -> URL {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        try "hello".write(to: dir.appendingPathComponent("hi.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    private func createSingleMountFile(content: String = "single file content") throws -> URL {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-single-file-\(UUID().uuidString).txt")
        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        return tempFile
    }
}
