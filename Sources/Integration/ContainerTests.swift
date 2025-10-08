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
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Crypto
import Foundation
import Logging

extension IntegrationSuite {
    func testProcessTrue() async throws {
        let id = "test-process-true"

        let bs = try await bootstrap()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/true"]
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
    }

    func testProcessFalse() async throws {
        let id = "test-process-false"

        let bs = try await bootstrap()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/false"]
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 1 else {
            throw IntegrationError.assert(msg: "process status \(status) != 1")
        }
    }

    final class BufferWriter: Writer {
        // `data` isn't used concurrently.
        nonisolated(unsafe) var data = Data()

        func write(_ data: Data) throws {
            guard data.count > 0 else {
                return
            }
            self.data.append(data)
        }
    }

    final class StdinBuffer: ReaderStream {
        let data: Data

        init(data: Data) {
            self.data = data
        }

        func stream() -> AsyncStream<Data> {
            let (stream, cont) = AsyncStream<Data>.makeStream()
            cont.yield(self.data)
            cont.finish()
            return stream
        }
    }

    func testProcessEchoHi() async throws {
        let id = "test-process-echo-hi"
        let bs = try await bootstrap()

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/echo", "hi"]
            config.process.stdout = buffer
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 1")
            }

            guard String(data: buffer.data, encoding: .utf8) == "hi\n" else {
                throw IntegrationError.assert(
                    msg: "process should have returned on stdout 'hi' != '\(String(data: buffer.data, encoding: .utf8)!)'")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testMultipleConcurrentProcesses() async throws {
        let id = "test-concurrent-processes"

        let bs = try await bootstrap()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "1000"]
        }

        do {
            try await container.create()
            try await container.start()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0...80 {
                    let exec = try await container.exec("exec-\(i)") { config in
                        config.arguments = ["/bin/true"]
                    }

                    group.addTask {
                        try await exec.start()
                        let status = try await exec.wait()
                        if status.exitCode != 0 {
                            throw IntegrationError.assert(msg: "process status \(status) != 0")
                        }
                        try await exec.delete()
                    }
                }

                // wait for all the exec'd processes.
                try await group.waitForAll()
                print("all group processes exit")

                // kill the init process.
                try await container.kill(SIGKILL)
                let status = try await container.wait()
                try await container.stop()
                print("Init process exited with: \(status)")
            }
        } catch {
            throw error
        }
    }

    func testMultipleConcurrentProcessesOutputStress() async throws {
        let id = "test-concurrent-processes-output-stress"
        let bs = try await bootstrap()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "1000"]
        }

        do {
            try await container.create()
            try await container.start()

            let buffer = BufferWriter()
            let exec = try await container.exec("expected-value") { config in
                config.arguments = [
                    "sh",
                    "-c",
                    "dd if=/dev/random of=/tmp/bytes bs=1M count=20 status=none ; sha256sum /tmp/bytes",
                ]
                config.stdout = buffer
            }

            try await exec.start()
            let status = try await exec.wait()
            if status.exitCode != 0 {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            let output = String(data: buffer.data, encoding: .utf8)!
            let expected = String(output.split(separator: " ").first!)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0...80 {
                    let idx = i
                    group.addTask {
                        let buffer = BufferWriter()
                        let exec = try await container.exec("exec-\(idx)") { config in
                            config.arguments = ["cat", "/tmp/bytes"]
                            config.stdout = buffer
                        }
                        try await exec.start()

                        let status = try await exec.wait()
                        if status.exitCode != 0 {
                            throw IntegrationError.assert(msg: "process \(idx) status \(status) != 0")
                        }

                        var hasher = SHA256()
                        hasher.update(data: buffer.data)
                        let hash = hasher.finalize().digestString.trimmingDigestPrefix
                        guard hash == expected else {
                            throw IntegrationError.assert(
                                msg: "process \(idx) output \(hash) != expected \(expected)")
                        }
                        try await exec.delete()
                    }
                }

                // wait for all the exec'd processes.
                try await group.waitForAll()
                print("all group processes exit")

                // kill the init process.
                try await container.kill(SIGKILL)
                try await container.wait()
                try await container.stop()
            }
        }
    }

    func testProcessUser() async throws {
        let id = "test-process-user"

        let bs = try await bootstrap()
        var buffer = BufferWriter()
        var container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/usr/bin/id"]
            config.process.user = .init(uid: 1, gid: 1, additionalGids: [1])
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        var status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        var expected = "uid=1(bin) gid=1(bin) groups=1(bin)"
        guard String(data: buffer.data, encoding: .utf8) == "\(expected)\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }

        buffer = BufferWriter()
        container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/usr/bin/id"]
            // Try some uid that doesn't exist. This is supported.
            config.process.user = .init(uid: 40000, gid: 40000)
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        expected = "uid=40000 gid=40000 groups=40000"
        guard String(data: buffer.data, encoding: .utf8) == "\(expected)\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }

        buffer = BufferWriter()
        container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/usr/bin/id"]
            // Try some uid that doesn't exist. This is supported.
            config.process.user = .init(username: "40000:40000")
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        expected = "uid=40000 gid=40000 groups=40000"
        guard String(data: buffer.data, encoding: .utf8) == "\(expected)\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }

        buffer = BufferWriter()
        container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/usr/bin/id"]
            // Now for our final trick, try and run a username that doesn't exist.
            config.process.user = .init(username: "thisdoesntexist")
            config.process.stdout = buffer
        }

        try await container.create()
        do {
            try await container.start()
        } catch {
            return
        }
        throw IntegrationError.assert(msg: "container start should have failed")
    }

    // Ensure if we ask for a terminal we set TERM.
    func testProcessTtyEnvvar() async throws {
        let id = "test-process-tty-envvar"

        let bs = try await bootstrap()
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["env"]
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

        let homeEnvvar = "TERM=xterm"
        guard str.contains(homeEnvvar) else {
            throw IntegrationError.assert(
                msg: "process should have TERM environment variable defined")
        }
    }

    // Make sure we set HOME by default if we can find it in /etc/passwd in the guest.
    func testProcessHomeEnvvar() async throws {
        let id = "test-process-home-envvar"

        let bs = try await bootstrap()
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["env"]
            config.process.user = .init(uid: 0, gid: 0)
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

        let homeEnvvar = "HOME=/root"
        guard str.contains(homeEnvvar) else {
            throw IntegrationError.assert(
                msg: "process should have HOME environment variable defined")
        }
    }

    func testProcessCustomHomeEnvvar() async throws {
        let id = "test-process-custom-home-envvar"

        let bs = try await bootstrap()
        let customHomeEnvvar = "HOME=/tmp/custom/home"
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sh", "-c", "echo HOME=$HOME"]
            config.process.environmentVariables.append(customHomeEnvvar)
            config.process.user = .init(uid: 0, gid: 0)
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard output.contains(customHomeEnvvar) else {
            throw IntegrationError.assert(msg: "process should have preserved custom HOME environment variable, expected \(customHomeEnvvar), got: \(output)")
        }
    }

    func testHostname() async throws {
        let id = "test-container-hostname"

        let bs = try await bootstrap()
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/hostname"]
            config.hostname = "foo-bar"
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
        let expected = "foo-bar"

        guard String(data: buffer.data, encoding: .utf8) == "\(expected)\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }

    func testHostsFile() async throws {
        let id = "test-container-hosts-file"

        let bs = try await bootstrap()
        let entry = Hosts.Entry.localHostIPV4(comment: "Testaroo")
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat", "/etc/hosts"]
            config.hosts = Hosts(entries: [entry])
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        let expected = entry.rendered
        guard String(data: buffer.data, encoding: .utf8) == "\(expected)\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }

    func testProcessStdin() async throws {
        let id = "test-container-stdin"

        let bs = try await bootstrap()
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat"]
            config.process.stdin = StdinBuffer(data: "Hello from test".data(using: .utf8)!)
            config.process.stdout = buffer
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
        let expected = "Hello from test"

        guard String(data: buffer.data, encoding: .utf8) == "\(expected)" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }

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

    func testCgroupLimits() async throws {
        let id = "test-cgroup-limits"

        let bs = try await bootstrap()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "infinity"]
            config.cpus = 2
            config.memoryInBytes = 512.mib()
        }

        do {
            try await container.create()
            try await container.start()

            // Start an exec with sleep infinity
            let sleepExec = try await container.exec("sleep-exec") { config in
                config.arguments = ["sleep", "infinity"]
            }
            try await sleepExec.start()

            // Verify we have 3 PIDs in cgroup.procs: init, exec sleep, and cat itself
            let procsBuffer = BufferWriter()
            let procsExec = try await container.exec("check-procs") { config in
                config.arguments = ["cat", "/sys/fs/cgroup/cgroup.procs"]
                config.stdout = procsBuffer
            }
            try await procsExec.start()
            var status = try await procsExec.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "check-procs status \(status) != 0")
            }
            try await procsExec.delete()

            guard let procsContent = String(data: procsBuffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to parse cgroup.procs")
            }
            let pids = procsContent.split(separator: "\n").filter { !$0.isEmpty }
            guard pids.count == 3 else {
                throw IntegrationError.assert(msg: "expected 3 PIDs in cgroup.procs, got \(pids.count): \(procsContent)")
            }

            // Verify memory limit
            let memoryBuffer = BufferWriter()
            let memoryExec = try await container.exec("check-memory") { config in
                config.arguments = ["cat", "/sys/fs/cgroup/memory.max"]
                config.stdout = memoryBuffer
            }
            try await memoryExec.start()
            status = try await memoryExec.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "check-memory status \(status) != 0")
            }
            try await memoryExec.delete()

            guard let memoryLimit = String(data: memoryBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to parse memory.max")
            }
            let expectedMemory = "\(512.mib())"
            guard memoryLimit == expectedMemory else {
                throw IntegrationError.assert(msg: "memory.max \(memoryLimit) != expected \(expectedMemory)")
            }

            // Verify CPU limit
            let cpuBuffer = BufferWriter()
            let cpuExec = try await container.exec("check-cpu") { config in
                config.arguments = ["cat", "/sys/fs/cgroup/cpu.max"]
                config.stdout = cpuBuffer
            }
            try await cpuExec.start()
            status = try await cpuExec.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "check-cpu status \(status) != 0")
            }
            try await cpuExec.delete()

            guard let cpuLimit = String(data: cpuBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to parse cpu.max")
            }
            let expectedCpu = "200000 100000"  // 2 CPUs: quota=200000, period=100000
            guard cpuLimit == expectedCpu else {
                throw IntegrationError.assert(msg: "cpu.max '\(cpuLimit)' != expected '\(expectedCpu)'")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    private func createMountDirectory() throws -> URL {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        try "hello".write(to: dir.appendingPathComponent("hi.txt"), atomically: true, encoding: .utf8)
        return dir
    }
}
