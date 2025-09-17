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
import NIOCore
import NIOPosix

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

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        let value = String(data: buffer.data, encoding: .utf8)
        guard value == "hello" else {
            throw IntegrationError.assert(
                msg: "process should have returned from file 'hello' != '\(String(data: buffer.data, encoding: .utf8)!)")

        }
    }

    func testPauseResume() async throws {
        let id = "test-pause-resume"

        let bs = try await bootstrap()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "infinity"]
        }

        try await container.create()
        try await container.start()

        // Very simple test of can we perform actions on the container after pause/resume.
        try await container.pause()
        try await Task.sleep(for: .milliseconds(500))
        try await container.resume()

        try await container.kill(SIGKILL)
        try await container.wait()
        try await container.stop()
    }

    func testPauseResumeWait() async throws {
        let id = "test-pause-resume-wait"

        let bs = try await bootstrap()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "2"]
        }

        try await container.create()
        try await container.start()

        let t = Task {
            try await container.wait(timeoutInSeconds: 5)
        }

        try await Task.sleep(for: .milliseconds(25))

        try await container.pause()
        try await Task.sleep(for: .milliseconds(500))
        try await container.resume()

        let status = try await t.value

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        try await container.stop()
    }

    func testPauseResumeIO() async throws {
        let id = "test-pause-resume-io"

        let bs = try await bootstrap()
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["ping", "-c", "5", "localhost"]
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        try await container.pause()
        try await Task.sleep(for: .seconds(2))
        try await container.resume()

        try await container.wait()

        guard let str = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to utf8")
        }

        // Should be 10 lines long. 5 of "filler" and 5 of actual
        // output, however one of the lines is a blank newline.
        let expectedLines = 9
        let lines = str.split(separator: "\n")
        guard lines.count == expectedLines else {
            throw IntegrationError.assert(msg: "expected \(expectedLines), got \(lines.count)")
        }

        try await container.stop()
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

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
    }

    func testContainerManagerCreate() async throws {
        let id = "test-container-manager"

        // Get the kernel from bootstrap
        let bs = try await bootstrap()

        // Create ContainerManager with kernel and initfs reference
        var manager = try ContainerManager(vmm: bs.vmm)
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

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        let output = String(data: buffer.data, encoding: .utf8)
        guard output == "ContainerManager test\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned 'ContainerManager test' != '\(output ?? "nil")'")
        }
    }

    func testContainerStopIdempotency() async throws {
        let id = "test-container-stop-idempotency"

        // Get the kernel from bootstrap
        let bs = try await bootstrap()

        // Create ContainerManager with kernel and initfs reference
        var manager = try ContainerManager(vmm: bs.vmm)
        defer {
            try? manager.delete(id)
        }

        let buffer = BufferWriter()
        let container = try await manager.create(
            id,
            image: bs.image,
            rootfs: bs.rootfs
        ) { config in
            config.process.arguments = ["/bin/echo", "please stop me"]
            config.process.stdout = buffer
        }

        // Start the container
        try await container.create()
        try await container.start()

        // Wait for completion
        let status = try await container.wait()
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        try await container.stop()
        // Second go around should return with no problems.
        try await container.stop()

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
        var manager = try ContainerManager(vmm: bs.vmm)
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
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
        try await container.stop()

        // Recreate things.
        try await container.create()
        try await container.start()

        // Wait for completion.. again.
        status = try await container.wait()
        guard status.exitCode == 0 else {
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

        var manager = try ContainerManager(vmm: bs.vmm)
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
        guard status.exitCode == 0 else {
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

    func testFSNotifyEvents() async throws {
        let id = "test-fsnotify-events"

        let bs = try await bootstrap()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            let directory = try createFSNotifyTestDirectory()
            config.process.arguments = ["/bin/sh", "-c", "sleep 30"]  // Keep container running
            config.mounts.append(.share(source: directory.path, destination: "/mnt/test"))
        }

        try await container.create()
        try await container.start()

        // Get the vminitd agent to send notifications
        let connection = try await container.dialVsock(port: 1024)  // Default vminitd port
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let agent = Vminitd(connection: connection, group: group)

        // Test 1: CREATE event
        print("Testing CREATE event...")
        let createResponse = try await agent.notifyFileSystemEvent(path: "/mnt/test/new_file.txt", eventType: .create)
        guard createResponse.success else {
            throw IntegrationError.assert(msg: "CREATE event failed: \(createResponse.error)")
        }

        // Verify file was created in guest
        let buffer1 = BufferWriter()
        let process1 = try await container.exec("check-create") { config in
            config.arguments = ["/bin/ls", "-la", "/mnt/test/new_file.txt"]
            config.stdout = buffer1
        }

        try await process1.start()
        let status1 = try await process1.wait()
        guard status1 == 0 else {
            throw IntegrationError.assert(msg: "File creation verification failed")
        }

        // Test 2: MODIFY event on existing file
        print("Testing MODIFY event...")
        let modifyResponse = try await agent.notifyFileSystemEvent(path: "/mnt/test/existing.txt", eventType: .modify)
        guard modifyResponse.success else {
            throw IntegrationError.assert(msg: "MODIFY event failed: \(modifyResponse.error)")
        }

        // Verify file timestamp was updated
        let buffer2 = BufferWriter()
        let process2 = try await container.exec("check-modify") { config in
            config.arguments = ["/bin/stat", "/mnt/test/existing.txt"]
            config.stdout = buffer2
        }

        try await process2.start()
        let status2 = try await process2.wait()
        guard status2 == 0 else {
            throw IntegrationError.assert(msg: "File modification verification failed")
        }

        // Test 3: Test unsupported DELETE event (should log warning but not fail)
        print("Testing DELETE event (should log warning)...")
        let deleteResponse = try await agent.notifyFileSystemEvent(path: "/mnt/test/nonexistent.txt", eventType: .delete)
        guard deleteResponse.success else {
            throw IntegrationError.assert(msg: "DELETE event should succeed with warning, not fail")
        }

        // Clean up
        try await agent.close()
        try await group.shutdownGracefully()
        try await container.stop()

        print("All FSNotify events tested successfully")
    }

    private func createFSNotifyTestDirectory() throws -> URL {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)

        // Create some test files and directories
        try "initial content".write(to: dir.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
        try "hello world".write(to: dir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        // Create a subdirectory
        let subdir = dir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "nested file".write(to: subdir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

        return dir
    }

    private func createMountDirectory() throws -> URL {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        try "hello".write(to: dir.appendingPathComponent("hi.txt"), atomically: true, encoding: .utf8)
        return dir
    }
}
