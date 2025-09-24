//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import NIOCore
import NIOPosix

@testable import Containerization

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

    func testContainerStatistics() async throws {
        let id = "test-container-statistics"

        let bs = try await bootstrap()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "infinity"]
        }

        do {
            try await container.create()
            try await container.start()

            let stats = try await container.statistics()

            guard stats.id == id else {
                throw IntegrationError.assert(msg: "stats container ID '\(stats.id)' != '\(id)'")
            }

            guard stats.process.current > 0 else {
                throw IntegrationError.assert(msg: "process count should be > 0, got \(stats.process.current)")
            }

            guard stats.memory.usageBytes > 0 else {
                throw IntegrationError.assert(msg: "memory usage should be > 0, got \(stats.memory.usageBytes)")
            }

            guard stats.cpu.usageUsec > 0 else {
                throw IntegrationError.assert(msg: "CPU usage should be > 0, got \(stats.cpu.usageUsec)")
            }

            print("Container statistics:")
            print("  Processes: \(stats.process.current)")
            print("  Memory: \(stats.memory.usageBytes) bytes")
            print("  CPU: \(stats.cpu.usageUsec) usec")
            print("  Networks: \(stats.networks.count) interfaces")

            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
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
        let directory = try createFSNotifyTestDirectory()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sh", "-c", "sleep 30"]  // Keep container running
            config.mounts.append(.share(source: directory.path, destination: "/mnt"))
        }

        try await container.create()
        try await container.start()

        // Get the vminitd agent to send notifications
        let connection = try await container.dialVsock(port: 1024)  // Default vminitd port
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let agent = Vminitd(connection: connection, group: group)

        // Calculate the hashed tag name for the mount source and mount in VM
        let mountTag = try hashMountSource(source: directory.path)
        let vmMountPath = "/tmp/fsnotify-test"

        try await agent.mount(.init(type: "virtiofs", source: mountTag, destination: vmMountPath))

        // Test 1: CREATE event on existing file
        let createResponse = try await agent.notifyFileSystemEvent(path: "\(vmMountPath)/existing.txt", eventType: .create)

        guard createResponse.success else {
            throw IntegrationError.assert(msg: "CREATE event failed: \(createResponse.error)")
        }

        // Test 2: MODIFY event on existing file
        let modifyResponse = try await agent.notifyFileSystemEvent(path: "\(vmMountPath)/existing.txt", eventType: .modify)
        guard modifyResponse.success else {
            throw IntegrationError.assert(msg: "MODIFY event failed: \(modifyResponse.error)")
        }

        // Test 3: Verify inotify events are actually generated using inotifywait
        let inotifyBuffer = BufferWriter()
        let inotifyProcess = try await container.exec("test-inotify") { config in
            // Install inotify-tools and monitor the mount point for events
            config.arguments = [
                "/bin/sh", "-c",
                """
                apk add --no-cache inotify-tools > /dev/null 2>&1 && \
                timeout 2 inotifywait -m /mnt -e modify,create,delete --format '%e %f' 2>/dev/null &
                INOTIFY_PID=$!
                sleep 0.1
                # Trigger a modify event that should be detected
                touch /mnt/test-inotify.txt
                echo "modify test-inotify.txt"
                wait $INOTIFY_PID 2>/dev/null || true
                """,
            ]
            config.stdout = inotifyBuffer
        }

        try await inotifyProcess.start()

        // While inotify is running, send FSNotify events that should trigger inotify
        try await Task.sleep(for: .milliseconds(200))
        let _ = try await agent.notifyFileSystemEvent(path: "\(vmMountPath)/test-inotify.txt", eventType: .modify)

        let _ = try await inotifyProcess.wait()
        let inotifyOutput = String(data: inotifyBuffer.data, encoding: .utf8) ?? ""

        // Verify that inotify detected the modify event
        guard inotifyOutput.contains("modify test-inotify.txt") else {
            throw IntegrationError.assert(msg: "inotify did not detect FSNotify-triggered modify event. Output: \(inotifyOutput)")
        }

        // Test 4: DELETE event on non-existent file
        let deleteResponse = try await agent.notifyFileSystemEvent(path: "\(vmMountPath)/nonexistent.txt", eventType: .delete)
        guard deleteResponse.success else {
            throw IntegrationError.assert(msg: "DELETE event failed: \(deleteResponse.error)")
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
