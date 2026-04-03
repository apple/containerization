//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Crypto
import Foundation
import Logging
import SystemPackage

extension IntegrationSuite {
    func testProcessTrue() async throws {
        let id = "test-process-true"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/true"]
            config.bootLog = bs.bootLog
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

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/false"]
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 1 else {
            throw IntegrationError.assert(msg: "process status \(status) != 1")
        }
    }

    final class DiscardingWriter: @unchecked Sendable, Writer {
        var count: Int = 0

        func write(_ data: Data) throws {
            count += data.count
        }

        func close() throws {
            return
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

        func close() throws {
            return
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

    final class ChunkedStdinBuffer: ReaderStream {
        let chunks: [Data]
        let delayMs: Int

        init(chunks: [Data], delayMs: Int = 0) {
            self.chunks = chunks
            self.delayMs = delayMs
        }

        func stream() -> AsyncStream<Data> {
            let chunks = self.chunks
            let delayMs = self.delayMs
            return AsyncStream { cont in
                Task {
                    for chunk in chunks {
                        if delayMs > 0 {
                            try? await Task.sleep(for: .milliseconds(delayMs))
                        }
                        cont.yield(chunk)
                    }
                    cont.finish()
                }
            }
        }
    }

    func testProcessEchoHi() async throws {
        let id = "test-process-echo-hi"
        let bs = try await bootstrap(id)

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/echo", "hi"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

    func testProcessNoExecutable() async throws {
        let id = "test-process-no-executable"
        let bs = try await bootstrap(id)

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["foobarbaz"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let _ = try await container.wait()
            try await container.stop()

            throw IntegrationError.assert(msg: "process didn't throw 'no executable' error")
        } catch {
            try? await container.stop()
            guard let err = error as? ContainerizationError,
                err.isCode(.internalError), err.description.contains("failed to find target executable")
            else {
                throw error
            }
        }
    }

    func testMultipleConcurrentProcesses() async throws {
        let id = "test-concurrent-processes"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "1000"]
            config.bootLog = bs.bootLog
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

                try await group.waitForAll()

                try await container.stop()
            }
        } catch {
            throw error
        }
    }

    func testMultipleConcurrentProcessesOutputStress() async throws {
        let id = "test-concurrent-processes-output-stress"
        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "1000"]
            config.bootLog = bs.bootLog
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

                try await group.waitForAll()
            }
            try await exec.delete()

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        }
    }

    func testProcessUser() async throws {
        let id = "test-process-user"

        let bs = try await bootstrap(id)
        var buffer = BufferWriter()
        var container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/usr/bin/id"]
            config.process.user = .init(uid: 1, gid: 1, additionalGids: [1])
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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
            config.bootLog = bs.bootLog
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
            config.bootLog = bs.bootLog
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
            config.bootLog = bs.bootLog
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

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["env"]
            config.process.terminal = true
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["env"]
            config.process.user = .init(uid: 0, gid: 0)
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

        let bs = try await bootstrap(id)
        let customHomeEnvvar = "HOME=/tmp/custom/home"
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sh", "-c", "echo HOME=$HOME"]
            config.process.environmentVariables.append(customHomeEnvvar)
            config.process.user = .init(uid: 0, gid: 0)
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/hostname"]
            config.hostname = "foo-bar"
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

    func testHostnameDefaultsToContainerID() async throws {
        let id = "test-container-hostname-default"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/hostname"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard String(data: buffer.data, encoding: .utf8) == "\(id)\n" else {
            throw IntegrationError.assert(
                msg: "hostname should default to container id '\(id)', got '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }

    func testHostsFile() async throws {
        let id = "test-container-hosts-file"

        let bs = try await bootstrap(id)
        let entry = Hosts.Entry.localHostIPV4(comment: "Testaroo")
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat", "/etc/hosts"]
            config.hosts = Hosts(entries: [entry])
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat"]
            config.process.stdin = StdinBuffer(data: "Hello from test".data(using: .utf8)!)
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            let directory = try createMountDirectory()
            config.process.arguments = ["/bin/cat", "/mnt/hi.txt"]
            config.mounts.append(.share(source: directory.path, destination: "/mnt"))
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

    func testNestedVirtualizationEnabled() async throws {
        let id = "test-nested-virt"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/true"]
            config.virtualization = true
            config.bootLog = bs.bootLog
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

        let bs = try await bootstrap(id)

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
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

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

        let bs = try await bootstrap(id)

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
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        try await container.stop()
        try await container.stop()

        let output = String(data: buffer.data, encoding: .utf8)
        guard output == "please stop me\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned 'ContainerManager test' != '\(output ?? "nil")'")
        }
    }

    func testContainerReuse() async throws {
        let id = "test-container-reuse"

        let bs = try await bootstrap(id)

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
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        var status = try await container.wait()
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
        try await container.stop()

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

        let bs = try await bootstrap(id)

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
            config.bootLog = bs.bootLog
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

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "infinity"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let stats = try await container.statistics()

            guard stats.id == id else {
                throw IntegrationError.assert(msg: "stats container ID '\(stats.id)' != '\(id)'")
            }

            guard let process = stats.process, process.current > 0 else {
                throw IntegrationError.assert(msg: "process count should be > 0, got \(stats.process?.current ?? 0)")
            }

            guard let memory = stats.memory, memory.usageBytes > 0 else {
                throw IntegrationError.assert(msg: "memory usage should be > 0, got \(stats.memory?.usageBytes ?? 0)")
            }

            guard let cpu = stats.cpu, cpu.usageUsec > 0 else {
                throw IntegrationError.assert(msg: "CPU usage should be > 0, got \(stats.cpu?.usageUsec ?? 0)")
            }

            print("Container statistics:")
            print("  Processes: \(process.current)")
            print("  Memory: \(memory.usageBytes) bytes")
            print("  CPU: \(cpu.usageUsec) usec")
            print("  Networks: \(stats.networks?.count ?? 0) interfaces")

            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCgroupLimits() async throws {
        let id = "test-cgroup-limits"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "infinity"]
            config.cpus = 2
            config.memoryInBytes = 512.mib()
            config.bootLog = bs.bootLog
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

            try await sleepExec.delete()

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testMemoryEventsOOMKill() async throws {
        let id = "test-memory-events-oom-kill"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "infinity"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Run a process that will exceed the memory limit and get OOM-killed
            let exec = try await container.exec("oom-trigger") { config in
                // First set a 2MB memory limit on the container's cgroup, then allocate more
                config.arguments = [
                    "sh",
                    "-c",
                    "echo 2097152 > /sys/fs/cgroup/memory.max && dd if=/dev/zero of=/dev/null bs=100M",
                ]
            }

            try await exec.start()
            let status = try await exec.wait()
            if status.exitCode == 0 {
                throw IntegrationError.assert(msg: "expected exit code > 0")
            }
            try await exec.delete()

            let stats = try await container.statistics(categories: .memoryEvents)

            guard let events = stats.memoryEvents else {
                throw IntegrationError.assert(msg: "expected memoryEvents to be present")
            }

            print("Memory events for container \(id):")
            print("  low: \(events.low)")
            print("  high: \(events.high)")
            print("  max: \(events.max)")
            print("  oom: \(events.oom)")
            print("  oomKill: \(events.oomKill)")

            guard events.oomKill > 0 else {
                throw IntegrationError.assert(msg: "expected oomKill > 0, got \(events.oomKill)")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testNoSerialConsole() async throws {
        let id = "test-no-serial-console"

        let bs = try await bootstrap(id)
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

    func testUnixSocketIntoGuest() async throws {
        let id = "test-unixsocket-into-guest"

        let bs = try await bootstrap(id)

        let hostSocketPath = try createHostUnixSocket()

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.sockets = [
                UnixSocketConfiguration(
                    source: URL(filePath: hostSocketPath),
                    destination: URL(filePath: "/tmp/test.sock"),
                    direction: .into
                )
            ]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Execute ls -l to check the socket exists and is indeed a socket
            let lsExec = try await container.exec("ls-socket") { config in
                config.arguments = ["ls", "-l", "/tmp/test.sock"]
                config.stdout = buffer
            }

            try await lsExec.start()
            let status = try await lsExec.wait()
            try await lsExec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "ls command failed with status \(status)")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to convert ls output to UTF8")
            }

            // Socket files in ls -l output start with 's'
            guard output.hasPrefix("s") else {
                throw IntegrationError.assert(
                    msg: "expected socket file (starting with 's'), got: \(output)")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testNonClosureConstructor() async throws {
        let id = "test-container-non-closure-constructor"

        let bs = try await bootstrap(id)
        let config = LinuxContainer.Configuration(
            process: LinuxProcessConfiguration(arguments: ["/bin/true"])
        )
        let container = try LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm,
            configuration: config
        )

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
    }

    private func createHostUnixSocket() throws -> String {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        let socketPath = dir.appendingPathComponent("test.sock").path

        let socket = try Socket(type: UnixType(path: socketPath))
        try socket.listen()

        return socketPath
    }

    private func createMountDirectory() throws -> URL {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        try "hello".write(to: dir.appendingPathComponent("hi.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    func testUnixSocketIntoGuestSymlink() async throws {
        let id = "test-unixsocket-into-guest-symlink"

        let bs = try await bootstrap(id)

        let hostSocketPath = try createHostUnixSocket()

        let buffer = BufferWriter()
        // Use /var/run/test.sock. Alpine has /var/run -> /run symlink
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.sockets = [
                UnixSocketConfiguration(
                    source: URL(filePath: hostSocketPath),
                    destination: URL(filePath: "/var/run/test.sock"),
                    direction: .into
                )
            ]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let lsExec = try await container.exec("ls-socket") { config in
                config.arguments = ["ls", "-l", "/var/run/test.sock"]
                config.stdout = buffer
            }

            try await lsExec.start()
            let status = try await lsExec.wait()
            try await lsExec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "ls command failed with status \(status)")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to convert ls output to UTF8")
            }

            // Socket files in ls -l output start with 's'
            guard output.hasPrefix("s") else {
                throw IntegrationError.assert(
                    msg: "expected socket file (starting with 's'), got: \(output)")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testBootLogFileHandle() async throws {
        let id = "test-bootlog-filehandle"

        let bs = try await bootstrap(id)

        // Create a pipe to capture boot log data
        let pipe = Pipe()
        let bootLog = BootLog.fileHandle(pipe.fileHandleForWriting)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/echo", "test complete"]
            config.bootLog = bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            try pipe.fileHandleForWriting.close()
            let bootLogData = try pipe.fileHandleForReading.readToEnd()
            guard let bootLogData = bootLogData, bootLogData.count > 0 else {
                throw IntegrationError.assert(
                    msg: "expected to receive boot log data from pipe, but got no data")
            }

            guard let bootLogString = String(data: bootLogData, encoding: .utf8) else {
                throw IntegrationError.assert(
                    msg: "failed to convert boot log data to UTF8 string")
            }

            guard bootLogString.count > 100 else {
                throw IntegrationError.assert(
                    msg: "boot log output smaller than expected: got \(bootLogString.count)")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testLargeStdioOutput() async throws {
        let id = "test-large-stdout-stderr-output"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "1000"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let stdoutBuffer = DiscardingWriter()
            let stderrBuffer = DiscardingWriter()

            let exec = try await container.exec("large-output") { config in
                config.arguments = [
                    "sh",
                    "-c",
                    """
                    dd if=/dev/zero bs=1M count=250 status=none && \
                    dd if=/dev/zero bs=1M count=250 status=none >&2
                    """,
                ]
                config.stdout = stdoutBuffer
                config.stderr = stderrBuffer
            }

            let started = CFAbsoluteTimeGetCurrent()

            try await exec.start()
            let status = try await exec.wait()

            let lasted = CFAbsoluteTimeGetCurrent() - started
            print("Test \(id) finished process ingesting stdio in \(lasted)")

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec process status \(status) != 0")
            }

            try await exec.delete()

            let expectedSize = 250 * 1024 * 1024
            guard stdoutBuffer.count == expectedSize else {
                throw IntegrationError.assert(
                    msg: "stdout size \(stdoutBuffer.count) != expected \(expectedSize)")
            }

            guard stderrBuffer.count == expectedSize else {
                throw IntegrationError.assert(
                    msg: "stderr size \(stderrBuffer.count) != expected \(expectedSize)")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testProcessDeleteIdempotency() async throws {
        let id = "test-process-delete-idempotency"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "1000"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Create an exec process
            let exec = try await container.exec("test-exec") { config in
                config.arguments = ["/bin/true"]
            }

            try await exec.start()
            let status = try await exec.wait()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec process status \(status) != 0")
            }

            // Call delete twice to verify idempotency
            try await exec.delete()
            try await exec.delete()  // Should be a no-op

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testMultipleExecsWithoutDelete() async throws {
        let id = "test-multiple-execs-without-delete"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "1000"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Create 3 exec processes without deleting them
            let exec1 = try await container.exec("exec-1") { config in
                config.arguments = ["/bin/true"]
            }
            try await exec1.start()
            let status1 = try await exec1.wait()
            guard status1.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec1 process status \(status1) != 0")
            }

            let exec2 = try await container.exec("exec-2") { config in
                config.arguments = ["/bin/true"]
            }
            try await exec2.start()
            let status2 = try await exec2.wait()
            guard status2.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec2 process status \(status2) != 0")
            }

            let exec3 = try await container.exec("exec-3") { config in
                config.arguments = ["/bin/true"]
            }
            try await exec3.start()
            let status3 = try await exec3.wait()
            guard status3.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec3 process status \(status3) != 0")
            }

            // Stop should handle cleanup of all exec processes gracefully
            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testNonExistentBinary() async throws {
        let id = "test-non-existent-binary"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["foo-bar-baz"]
            config.bootLog = bs.bootLog
        }

        try await container.create()
        do {
            try await container.start()
        } catch {
            return
        }
        try await container.stop()
        throw IntegrationError.assert(msg: "container start should have failed")
    }

    // MARK: - Capability Tests

    func testCapabilitiesSysAdmin() async throws {
        let id = "test-capabilities-sysadmin"

        let bs = try await bootstrap(id)

        // First test: without CAP_SYS_ADMIN (should be denied)
        let bufferDenied = BufferWriter()
        let containerWithoutSysAdmin = try LinuxContainer("\(id)-denied", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = LinuxCapabilities()
            config.process.arguments = ["/bin/sh", "-c", "mount -t tmpfs tmpfs /tmp || echo 'mount failed as expected'"]
            config.process.stdout = bufferDenied
            config.bootLog = bs.bootLog
        }

        try await containerWithoutSysAdmin.create()
        try await containerWithoutSysAdmin.start()

        var status = try await containerWithoutSysAdmin.wait()
        try await containerWithoutSysAdmin.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container should have run successfully, got exit code \(status.exitCode)")
        }

        guard let outputDenied = String(data: bufferDenied.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard outputDenied.contains("mount failed as expected") else {
            throw IntegrationError.assert(msg: "expected mount failure message, got: \(outputDenied)")
        }

        // Second test: with CAP_SYS_ADMIN (should succeed)
        let containerWithSysAdmin = try LinuxContainer("\(id)-allowed", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = LinuxCapabilities(capabilities: [.sysAdmin])
            config.process.arguments = ["/bin/sh", "-c", "mount -t tmpfs tmpfs /tmp"]
            config.bootLog = bs.bootLog
        }

        try await containerWithSysAdmin.create()
        try await containerWithSysAdmin.start()

        status = try await containerWithSysAdmin.wait()
        try await containerWithSysAdmin.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container with CAP_SYS_ADMIN should mount successfully, got exit code \(status.exitCode)")
        }
    }

    func testCapabilitiesNetAdmin() async throws {
        let id = "test-capabilities-netadmin"

        let bs = try await bootstrap(id)

        // First test: without CAP_NET_ADMIN (should be denied)
        let bufferDenied = BufferWriter()
        let containerWithoutNetAdmin = try LinuxContainer("\(id)-denied", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = LinuxCapabilities()
            config.process.arguments = ["/bin/sh", "-c", "ip link set lo down 2>/dev/null || echo 'network operation denied as expected'"]
            config.process.stdout = bufferDenied
            config.bootLog = bs.bootLog
        }

        try await containerWithoutNetAdmin.create()
        try await containerWithoutNetAdmin.start()

        var status = try await containerWithoutNetAdmin.wait()
        try await containerWithoutNetAdmin.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container should handle network denial gracefully, got exit code \(status.exitCode)")
        }

        guard let outputDenied = String(data: bufferDenied.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard outputDenied.contains("network operation denied as expected") else {
            throw IntegrationError.assert(msg: "expected network denial message, got: \(outputDenied)")
        }

        // Second test: with CAP_NET_ADMIN (should succeed)
        let bufferAllowed = BufferWriter()
        let containerWithNetAdmin = try LinuxContainer("\(id)-allowed", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = LinuxCapabilities(capabilities: [.netAdmin])
            config.process.arguments = ["/bin/sh", "-c", "ip link set lo down && ip link set lo up"]
            config.process.stdout = bufferAllowed
            config.bootLog = bs.bootLog
        }

        try await containerWithNetAdmin.create()
        try await containerWithNetAdmin.start()

        status = try await containerWithNetAdmin.wait()
        try await containerWithNetAdmin.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container with CAP_NET_ADMIN should perform network operations, got exit code \(status.exitCode)")
        }
    }

    func testCapabilitiesOCIDefault() async throws {
        let id = "test-capabilities-OCI-default"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            // Use default capability set
            config.process.capabilities = .defaultOCICapabilities
            config.process.arguments = ["/bin/sh", "-c", "echo 'Running with OCI default capabilities'"]
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container with OCI default capabilities should run, got exit code \(status.exitCode)")
        }
    }

    func testCapabilitiesAllCapabilities() async throws {
        let id = "test-capabilities-all"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = .allCapabilities
            config.process.arguments = ["/bin/sh", "-c", "mount -t tmpfs tmpfs /tmp && ip link set lo down"]
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container with all capabilities should perform all operations, got exit code \(status.exitCode)")
        }
    }

    func testCapabilitiesFileOwnership() async throws {
        let id = "test-capabilities-chown"

        let bs = try await bootstrap(id)

        // First test: without CAP_CHOWN
        let bufferDenied = BufferWriter()
        let containerWithoutChown = try LinuxContainer("\(id)-denied", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = LinuxCapabilities()
            config.process.arguments = ["/bin/sh", "-c", "touch /tmp/testfile && chown 1000:1000 /tmp/testfile 2>/dev/null || echo 'chown denied as expected'"]
            config.process.stdout = bufferDenied
            config.bootLog = bs.bootLog
        }

        try await containerWithoutChown.create()
        try await containerWithoutChown.start()

        var status = try await containerWithoutChown.wait()
        try await containerWithoutChown.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container should handle chown denial gracefully, got exit code \(status.exitCode)")
        }

        guard let outputDenied = String(data: bufferDenied.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard outputDenied.contains("chown denied as expected") else {
            throw IntegrationError.assert(msg: "expected chown denial message, got: \(outputDenied)")
        }

        // Second test: with CAP_CHOWN
        let bufferAllowed = BufferWriter()
        let containerWithChown = try LinuxContainer("\(id)-allowed", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = LinuxCapabilities(capabilities: [.chown])
            config.process.arguments = ["/bin/sh", "-c", "touch /tmp/testfile && chown 1000:1000 /tmp/testfile"]
            config.process.stdout = bufferAllowed
            config.bootLog = bs.bootLog
        }

        try await containerWithChown.create()
        try await containerWithChown.start()

        status = try await containerWithChown.wait()
        try await containerWithChown.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container with CAP_CHOWN should succeed, got exit code \(status.exitCode)")
        }
    }

    func testCopyIn() async throws {
        let id = "test-copy-in"

        let bs = try await bootstrap(id)

        // Create a temp file on the host with known content
        let testContent = "Hello from the host! This is a copyIn test."
        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("test-input.txt")
        try testContent.write(to: hostFile, atomically: true, encoding: .utf8)

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Copy the file into the container
            try await container.copyIn(
                from: hostFile,
                to: URL(filePath: "/tmp/copied-file.txt")
            )

            // Verify the file exists and has correct content
            let exec = try await container.exec("verify-copy") { config in
                config.arguments = ["cat", "/tmp/copied-file.txt"]
                config.stdout = buffer
            }

            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "cat command failed with status \(status)")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to convert output to UTF8")
            }

            guard output == testContent else {
                throw IntegrationError.assert(
                    msg: "copied file content mismatch: expected '\(testContent)', got '\(output)'")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyOut() async throws {
        let id = "test-copy-out"

        let bs = try await bootstrap(id)

        let testContent = "Hello from the guest! This is a copyOut test."
        let hostDestination = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("test-output.txt")

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Create a file inside the container
            let exec = try await container.exec("create-file") { config in
                config.arguments = ["sh", "-c", "echo -n '\(testContent)' > /tmp/guest-file.txt"]
            }

            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "failed to create file in guest, status \(status)")
            }

            // Copy the file out of the container
            try await container.copyOut(
                from: URL(filePath: "/tmp/guest-file.txt"),
                to: hostDestination
            )

            // Verify the file was copied correctly
            let copiedContent = try String(contentsOf: hostDestination, encoding: .utf8)

            guard copiedContent == testContent else {
                throw IntegrationError.assert(
                    msg: "copied file content mismatch: expected '\(testContent)', got '\(copiedContent)'")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyLargeFile() async throws {
        let id = "test-copy-large-file"

        let bs = try await bootstrap(id)

        // Create a 10MB file on the host with a repeating pattern
        let fileSize = 10 * 1024 * 1024
        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("large-file.bin")

        // Generate data with a repeating pattern
        let pattern = Data("ContainerizationCopyTest".utf8)
        var testData = Data(capacity: fileSize)
        while testData.count < fileSize {
            testData.append(pattern)
        }
        testData = testData.prefix(fileSize)
        try testData.write(to: hostFile)

        let hostDestination = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("large-file-out.bin")

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Copy large file into the container
            try await container.copyIn(
                from: hostFile,
                to: URL(filePath: "/tmp/large-file.bin")
            )

            // Copy it back out
            try await container.copyOut(
                from: URL(filePath: "/tmp/large-file.bin"),
                to: hostDestination
            )

            // Verify the content matches
            let copiedData = try Data(contentsOf: hostDestination)

            guard copiedData.count == testData.count else {
                throw IntegrationError.assert(
                    msg: "file size mismatch: expected \(testData.count), got \(copiedData.count)")
            }

            guard copiedData == testData else {
                throw IntegrationError.assert(msg: "file content mismatch after round-trip copy")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyInDirectory() async throws {
        let id = "test-copy-in-dir"

        let bs = try await bootstrap(id)

        // Create a temp directory with files, a subdirectory, and a symlink.
        let hostDir = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("test-dir")
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        try "file1 content".write(to: hostDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)

        let subDir = hostDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "file2 content".write(to: subDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        try FileManager.default.createSymbolicLink(
            at: hostDir.appendingPathComponent("link.txt"),
            withDestinationURL: hostDir.appendingPathComponent("file1.txt")
        )

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Copy the directory into the container.
            try await container.copyIn(
                from: hostDir,
                to: URL(filePath: "/tmp/copied-dir")
            )

            // Verify file1.txt exists with correct content.
            let buffer1 = BufferWriter()
            let exec1 = try await container.exec("verify-file1") { config in
                config.arguments = ["cat", "/tmp/copied-dir/file1.txt"]
                config.stdout = buffer1
            }
            try await exec1.start()
            let status1 = try await exec1.wait()
            try await exec1.delete()

            guard status1.exitCode == 0 else {
                throw IntegrationError.assert(msg: "cat file1.txt failed with status \(status1)")
            }
            guard String(data: buffer1.data, encoding: .utf8) == "file1 content" else {
                throw IntegrationError.assert(msg: "file1.txt content mismatch")
            }

            // Verify subdir/file2.txt exists with correct content.
            let buffer2 = BufferWriter()
            let exec2 = try await container.exec("verify-file2") { config in
                config.arguments = ["cat", "/tmp/copied-dir/subdir/file2.txt"]
                config.stdout = buffer2
            }
            try await exec2.start()
            let status2 = try await exec2.wait()
            try await exec2.delete()

            guard status2.exitCode == 0 else {
                throw IntegrationError.assert(msg: "cat subdir/file2.txt failed with status \(status2)")
            }
            guard String(data: buffer2.data, encoding: .utf8) == "file2 content" else {
                throw IntegrationError.assert(msg: "subdir/file2.txt content mismatch")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyOutDirectory() async throws {
        let id = "test-copy-out-dir"

        let bs = try await bootstrap(id)

        let hostDestination = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("copied-out-dir")

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Create a directory structure inside the container.
            let exec = try await container.exec("create-dir") { config in
                config.arguments = [
                    "sh", "-c",
                    "mkdir -p /tmp/guest-dir/subdir && echo -n 'guest file1' > /tmp/guest-dir/file1.txt && echo -n 'guest file2' > /tmp/guest-dir/subdir/file2.txt",
                ]
            }
            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "failed to create directory in guest, status \(status)")
            }

            // Copy the directory out of the container.
            try await container.copyOut(
                from: URL(filePath: "/tmp/guest-dir"),
                to: hostDestination
            )

            // Verify file1.txt was copied correctly.
            let file1Content = try String(contentsOf: hostDestination.appendingPathComponent("file1.txt"), encoding: .utf8)
            guard file1Content == "guest file1" else {
                throw IntegrationError.assert(
                    msg: "file1.txt content mismatch: expected 'guest file1', got '\(file1Content)'")
            }

            // Verify subdir/file2.txt was copied correctly.
            let file2Content = try String(
                contentsOf: hostDestination.appendingPathComponent("subdir").appendingPathComponent("file2.txt"),
                encoding: .utf8
            )
            guard file2Content == "guest file2" else {
                throw IntegrationError.assert(
                    msg: "subdir/file2.txt content mismatch: expected 'guest file2', got '\(file2Content)'")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyEmptyFile() async throws {
        let id = "test-copy-empty-file"

        let bs = try await bootstrap(id)

        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("empty.txt")
        try Data().write(to: hostFile)

        let hostDestination = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("empty-out.txt")

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Copy empty file in.
            try await container.copyIn(
                from: hostFile,
                to: URL(filePath: "/tmp/empty.txt")
            )

            // Verify it exists and is empty in the guest.
            let buffer = BufferWriter()
            let exec = try await container.exec("verify-empty") { config in
                config.arguments = ["stat", "-c", "%s", "/tmp/empty.txt"]
                config.stdout = buffer
            }
            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "stat failed with status \(status)")
            }
            let sizeStr = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sizeStr == "0" else {
                throw IntegrationError.assert(msg: "empty file should have size 0, got '\(sizeStr ?? "nil")'")
            }

            // Copy it back out.
            try await container.copyOut(
                from: URL(filePath: "/tmp/empty.txt"),
                to: hostDestination
            )

            let copiedData = try Data(contentsOf: hostDestination)
            guard copiedData.isEmpty else {
                throw IntegrationError.assert(msg: "round-tripped empty file should be empty, got \(copiedData.count) bytes")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyEmptyDirectory() async throws {
        let id = "test-copy-empty-dir"

        let bs = try await bootstrap(id)

        let hostDir = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("empty-dir")
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Copy empty directory in.
            try await container.copyIn(
                from: hostDir,
                to: URL(filePath: "/tmp/empty-dir")
            )

            // Verify it exists and is a directory.
            let buffer = BufferWriter()
            let exec = try await container.exec("verify-empty-dir") { config in
                config.arguments = ["sh", "-c", "test -d /tmp/empty-dir && ls -a /tmp/empty-dir | wc -l"]
                config.stdout = buffer
            }
            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "empty dir check failed with status \(status)")
            }

            // ls -a shows . and .. so count should be 2 for an empty dir.
            let countStr = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard countStr == "2" else {
                throw IntegrationError.assert(msg: "empty dir should have 2 entries (. and ..), got '\(countStr ?? "nil")'")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyBinaryFile() async throws {
        let id = "test-copy-binary"

        let bs = try await bootstrap(id)

        // Create a file with all 256 byte values to test binary safety.
        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("binary.bin")
        var binaryData = Data(count: 256 * 64)
        for i in 0..<binaryData.count {
            binaryData[i] = UInt8(i % 256)
        }
        try binaryData.write(to: hostFile)

        let hostDestination = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("binary-out.bin")

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            try await container.copyIn(
                from: hostFile,
                to: URL(filePath: "/tmp/binary.bin")
            )

            try await container.copyOut(
                from: URL(filePath: "/tmp/binary.bin"),
                to: hostDestination
            )

            let copiedData = try Data(contentsOf: hostDestination)

            guard copiedData.count == binaryData.count else {
                throw IntegrationError.assert(
                    msg: "binary file size mismatch: expected \(binaryData.count), got \(copiedData.count)")
            }
            guard copiedData == binaryData else {
                throw IntegrationError.assert(msg: "binary file content mismatch after round-trip")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyMultipleFiles() async throws {
        let id = "test-copy-multiple"

        let bs = try await bootstrap(id)

        let tmpDir = FileManager.default.uniqueTemporaryDirectory(create: true)
        let files = (0..<5).map { i in
            (
                host: tmpDir.appendingPathComponent("file\(i).txt"),
                guest: URL(filePath: "/tmp/multi/file\(i).txt"),
                content: "Content of file \(i) with some padding: \(String(repeating: "x", count: i * 1000))"
            )
        }

        for file in files {
            try file.content.write(to: file.host, atomically: true, encoding: .utf8)
        }

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Copy all files in sequentially.
            for file in files {
                try await container.copyIn(
                    from: file.host,
                    to: file.guest,
                    createParents: true
                )
            }

            // Verify each file.
            for (i, file) in files.enumerated() {
                let buffer = BufferWriter()
                let exec = try await container.exec("verify-\(i)") { config in
                    config.arguments = ["cat", file.guest.path]
                    config.stdout = buffer
                }
                try await exec.start()
                let status = try await exec.wait()
                try await exec.delete()

                guard status.exitCode == 0 else {
                    throw IntegrationError.assert(msg: "cat file\(i).txt failed with status \(status)")
                }
                let output = String(data: buffer.data, encoding: .utf8)
                guard output == file.content else {
                    throw IntegrationError.assert(msg: "file\(i).txt content mismatch")
                }
            }

            // Copy all files back out and verify.
            for (i, file) in files.enumerated() {
                let outPath = tmpDir.appendingPathComponent("out-file\(i).txt")
                try await container.copyOut(
                    from: file.guest,
                    to: outPath
                )
                let copiedContent = try String(contentsOf: outPath, encoding: .utf8)
                guard copiedContent == file.content else {
                    throw IntegrationError.assert(msg: "file\(i).txt round-trip content mismatch")
                }
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyDirectoryRoundTrip() async throws {
        let id = "test-copy-dir-rt"

        let bs = try await bootstrap(id)

        // Create a directory tree with varied content: nested dirs, different sizes, binary data.
        let hostDir = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("dir-rt")
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)

        // Top-level files.
        try "top level".write(to: hostDir.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
        try Data(repeating: 0xAB, count: 4096).write(to: hostDir.appendingPathComponent("binary.bin"))

        // Nested 3 levels deep.
        let deep = hostDir.appendingPathComponent("a").appendingPathComponent("b").appendingPathComponent("c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "deep file".write(to: deep.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

        // Empty subdirectory.
        let emptySubdir = hostDir.appendingPathComponent("empty-sub")
        try FileManager.default.createDirectory(at: emptySubdir, withIntermediateDirectories: true)

        // File with special characters in content (not name).
        try "line1\nline2\ttab\r\nwindows\0null".write(
            to: hostDir.appendingPathComponent("special.txt"), atomically: true, encoding: .utf8)

        let hostDestination = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("dir-rt-out")

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Copy in.
            try await container.copyIn(
                from: hostDir,
                to: URL(filePath: "/tmp/dir-rt")
            )

            // Copy back out.
            try await container.copyOut(
                from: URL(filePath: "/tmp/dir-rt"),
                to: hostDestination
            )

            // Verify root.txt.
            let rootContent = try String(contentsOf: hostDestination.appendingPathComponent("root.txt"), encoding: .utf8)
            guard rootContent == "top level" else {
                throw IntegrationError.assert(msg: "root.txt mismatch: '\(rootContent)'")
            }

            // Verify binary.bin.
            let binaryContent = try Data(contentsOf: hostDestination.appendingPathComponent("binary.bin"))
            guard binaryContent == Data(repeating: 0xAB, count: 4096) else {
                throw IntegrationError.assert(msg: "binary.bin mismatch")
            }

            // Verify deep nested file.
            let deepOut =
                hostDestination
                .appendingPathComponent("a")
                .appendingPathComponent("b")
                .appendingPathComponent("c")
                .appendingPathComponent("deep.txt")
            let deepContent = try String(contentsOf: deepOut, encoding: .utf8)
            guard deepContent == "deep file" else {
                throw IntegrationError.assert(msg: "deep.txt mismatch: '\(deepContent)'")
            }

            // Verify empty subdirectory exists.
            var isDir: ObjCBool = false
            let emptySubdirExists = FileManager.default.fileExists(
                atPath: hostDestination.appendingPathComponent("empty-sub").path,
                isDirectory: &isDir
            )
            guard emptySubdirExists && isDir.boolValue else {
                throw IntegrationError.assert(msg: "empty-sub directory should exist after round trip")
            }

            // Verify special characters file.
            let specialContent = try String(
                contentsOf: hostDestination.appendingPathComponent("special.txt"), encoding: .utf8)
            guard specialContent == "line1\nline2\ttab\r\nwindows\0null" else {
                throw IntegrationError.assert(msg: "special.txt mismatch")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyInCreateParents() async throws {
        let id = "test-copy-parents"

        let bs = try await bootstrap(id)

        let testContent = "create parents test"
        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("parents-test.txt")
        try testContent.write(to: hostFile, atomically: true, encoding: .utf8)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Copy to a deeply nested path that doesn't exist yet.
            try await container.copyIn(
                from: hostFile,
                to: URL(filePath: "/tmp/a/b/c/d/e/file.txt"),
                createParents: true
            )

            // Verify the file got there.
            let buffer = BufferWriter()
            let exec = try await container.exec("verify-parents") { config in
                config.arguments = ["cat", "/tmp/a/b/c/d/e/file.txt"]
                config.stdout = buffer
            }
            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "cat failed with status \(status)")
            }
            guard String(data: buffer.data, encoding: .utf8) == testContent else {
                throw IntegrationError.assert(msg: "content mismatch after copy with createParents")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyFilePermissions() async throws {
        let id = "test-copy-perms"

        let bs = try await bootstrap(id)

        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("perms-test.sh")
        try "#!/bin/sh\necho hello".write(to: hostFile, atomically: true, encoding: .utf8)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Copy with executable permissions.
            try await container.copyIn(
                from: hostFile,
                to: URL(filePath: "/tmp/perms-test.sh"),
                mode: 0o755
            )

            // Verify the file is executable by running it.
            let buffer = BufferWriter()
            let exec = try await container.exec("run-script") { config in
                config.arguments = ["/tmp/perms-test.sh"]
                config.stdout = buffer
            }
            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "script execution failed with status \(status)")
            }
            let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard output == "hello" else {
                throw IntegrationError.assert(msg: "script output mismatch: '\(output ?? "nil")'")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testCopyLargeDirectory() async throws {
        let id = "test-copy-large-dir"

        let bs = try await bootstrap(id)

        // Create a directory with many files to stress the archive path.
        let hostDir = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("large-dir")
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)

        let fileCount = 100
        for i in 0..<fileCount {
            let content = "File \(i): \(String(repeating: String(i), count: 512))"
            try content.write(
                to: hostDir.appendingPathComponent("file-\(String(format: "%03d", i)).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let hostDestination = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("large-dir-out")

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            try await container.copyIn(
                from: hostDir,
                to: URL(filePath: "/tmp/large-dir")
            )

            // Verify file count in the guest.
            let buffer = BufferWriter()
            let exec = try await container.exec("count-files") { config in
                config.arguments = ["sh", "-c", "ls /tmp/large-dir/*.txt | wc -l"]
                config.stdout = buffer
            }
            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "ls | wc -l failed with status \(status)")
            }
            let countStr = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard countStr == "\(fileCount)" else {
                throw IntegrationError.assert(msg: "expected \(fileCount) files in guest, got '\(countStr ?? "nil")'")
            }

            // Copy back out.
            try await container.copyOut(
                from: URL(filePath: "/tmp/large-dir"),
                to: hostDestination
            )

            // Spot-check a few files.
            for i in [0, fileCount / 2, fileCount - 1] {
                let expectedContent = "File \(i): \(String(repeating: String(i), count: 512))"
                let actualContent = try String(
                    contentsOf: hostDestination.appendingPathComponent("file-\(String(format: "%03d", i)).txt"),
                    encoding: .utf8
                )
                guard actualContent == expectedContent else {
                    throw IntegrationError.assert(msg: "file-\(String(format: "%03d", i)).txt content mismatch after round trip")
                }
            }

            // Verify total file count on host.
            let outFiles = try FileManager.default.contentsOfDirectory(atPath: hostDestination.path)
            guard outFiles.count == fileCount else {
                throw IntegrationError.assert(
                    msg: "expected \(fileCount) files on host after copyOut, got \(outFiles.count)")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testReadOnlyRootfs() async throws {
        let id = "test-readonly-rootfs"

        let bs = try await bootstrap(id)
        var rootfs = bs.rootfs
        rootfs.options.append("ro")
        let container = try LinuxContainer(id, rootfs: rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["touch", "/testfile"]
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        // touch should fail on a read-only rootfs
        guard status.exitCode != 0 else {
            throw IntegrationError.assert(msg: "touch should have failed on read-only rootfs")
        }
    }

    func testReadOnlyRootfsHostsFileWritten() async throws {
        let id = "test-readonly-rootfs-hosts"

        let bs = try await bootstrap(id)
        var rootfs = bs.rootfs
        rootfs.options.append("ro")
        let buffer = BufferWriter()
        let entry = Hosts.Entry.localHostIPV4(comment: "ReadOnlyTest")
        let container = try LinuxContainer(id, rootfs: rootfs, vmm: bs.vmm) { config in
            // Verify /etc/hosts was written before rootfs was remounted read-only
            config.process.arguments = ["cat", "/etc/hosts"]
            config.process.stdout = buffer
            config.hosts = Hosts(entries: [entry])
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "cat /etc/hosts failed with status \(status)")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard output.contains("ReadOnlyTest") else {
            throw IntegrationError.assert(msg: "expected /etc/hosts to contain our entry, got: \(output)")
        }
    }

    func testReadOnlyRootfsDNSConfigured() async throws {
        let id = "test-readonly-rootfs-dns"

        let bs = try await bootstrap(id)
        var rootfs = bs.rootfs
        rootfs.options.append("ro")
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: rootfs, vmm: bs.vmm) { config in
            // Verify /etc/resolv.conf was written before rootfs was remounted read-only
            config.process.arguments = ["cat", "/etc/resolv.conf"]
            config.process.stdout = buffer
            config.dns = DNS(nameservers: ["8.8.8.8", "8.8.4.4"])
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "cat /etc/resolv.conf failed with status \(status)")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard output.contains("8.8.8.8") && output.contains("8.8.4.4") else {
            throw IntegrationError.assert(msg: "expected /etc/resolv.conf to contain DNS servers, got: \(output)")
        }
    }

    func testLargeStdinInput() async throws {
        let id = "test-large-stdin-input"

        let bs = try await bootstrap(id)

        let inputSize = 128 * 1024
        let inputData = Data(repeating: 0x41, count: inputSize)  // 'A' repeated

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat"]
            config.process.stdin = StdinBuffer(data: inputData)
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            guard buffer.data.count == inputSize else {
                throw IntegrationError.assert(
                    msg: "output size \(buffer.data.count) != input size \(inputSize)")
            }

            guard buffer.data == inputData else {
                throw IntegrationError.assert(msg: "output data does not match input data")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testExecLargeStdinInput() async throws {
        let id = "test-exec-large-stdin-input"
        let bs = try await bootstrap(id)

        let inputSize = 128 * 1024
        let inputData = Data(repeating: 0x42, count: inputSize)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let buffer = BufferWriter()
            let exec = try await container.exec("large-stdin-exec") { config in
                config.arguments = ["cat"]
                config.stdin = StdinBuffer(data: inputData)
                config.stdout = buffer
            }

            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec status \(status) != 0")
            }

            guard buffer.data.count == inputSize else {
                throw IntegrationError.assert(msg: "output size \(buffer.data.count) != \(inputSize)")
            }

            guard buffer.data == inputData else {
                throw IntegrationError.assert(msg: "output data mismatch")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testExecCustomPathResolution() async throws {
        let id = "test-exec-custom-path"
        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "1000"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Create a script in a non-standard directory
            let setup = try await container.exec("setup") { config in
                config.arguments = [
                    "sh", "-c",
                    "mkdir -p /tmp/custom-bin && printf '#!/bin/sh\\necho CUSTOM_PATH_OK' > /tmp/custom-bin/mytest && chmod +x /tmp/custom-bin/mytest",
                ]
            }
            try await setup.start()
            let setupStatus = try await setup.wait()
            try await setup.delete()
            guard setupStatus.exitCode == 0 else {
                throw IntegrationError.assert(msg: "setup failed: \(setupStatus)")
            }

            // Exec bare command with custom PATH — this exercises ExecCommand.swift
            let buffer = BufferWriter()
            let exec = try await container.exec("custom-path") { config in
                config.arguments = ["mytest"]
                config.environmentVariables = ["PATH=/tmp/custom-bin"]
                config.stdout = buffer
            }
            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec with custom PATH failed: \(status)")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to read output")
            }
            guard output.contains("CUSTOM_PATH_OK") else {
                throw IntegrationError.assert(msg: "expected CUSTOM_PATH_OK, got: \(output)")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testStdinExplicitClose() async throws {
        let id = "test-stdin-explicit-close"
        let bs = try await bootstrap(id)

        let inputData = "explicit close test\n".data(using: .utf8)!
        let buffer = BufferWriter()

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let exec = try await container.exec("stdin-close-exec") { config in
                config.arguments = ["head", "-n", "1"]
                config.stdin = StdinBuffer(data: inputData)
                config.stdout = buffer
            }

            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec status \(status) != 0")
            }

            guard buffer.data == inputData else {
                throw IntegrationError.assert(msg: "output mismatch")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testStdinBinaryData() async throws {
        let id = "test-stdin-binary-data"
        let bs = try await bootstrap(id)

        var inputData = Data()
        for i: UInt8 in 0...255 {
            inputData.append(contentsOf: [UInt8](repeating: i, count: 256))
        }

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat"]
            config.process.stdin = StdinBuffer(data: inputData)
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            guard buffer.data == inputData else {
                throw IntegrationError.assert(msg: "binary data mismatch")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testStdinMultipleChunks() async throws {
        let id = "test-stdin-multiple-chunks"
        let bs = try await bootstrap(id)

        let chunks = (0..<10).map { i in
            Data(repeating: UInt8(0x30 + i), count: 10 * 1024)
        }
        let expectedData = chunks.reduce(Data()) { $0 + $1 }

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat"]
            config.process.stdin = ChunkedStdinBuffer(chunks: chunks, delayMs: 10)
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            guard buffer.data == expectedData else {
                throw IntegrationError.assert(msg: "chunked data mismatch")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testStdinVeryLarge() async throws {
        let id = "test-stdin-very-large"
        let bs = try await bootstrap(id)

        let inputSize = 10 * 1024 * 1024
        let inputData = Data(repeating: 0x58, count: inputSize)

        let stdout = DiscardingWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["wc", "-c"]
            config.process.stdin = StdinBuffer(data: inputData)
            config.process.stdout = stdout
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            guard stdout.count > 0 else {
                throw IntegrationError.assert(msg: "no output from wc")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    @available(macOS 26.0, *)
    func testInterfaceMTU() async throws {
        let id = "test-interface-mtu"
        let bs = try await bootstrap(id)

        let customMTU: UInt32 = 1400
        var network = try VmnetNetwork()
        defer {
            try? network.releaseInterface(id)
        }

        guard let interface = try network.createInterface(id, mtu: customMTU) else {
            throw IntegrationError.assert(msg: "failed to create network interface")
        }

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.interfaces = [interface]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Check the MTU of eth0
            let exec = try await container.exec("check-mtu") { config in
                config.arguments = ["ip", "link", "show", "eth0"]
                config.stdout = buffer
            }

            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "ip link show failed with status \(status)")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to convert output to UTF8")
            }

            // Output should contain "mtu 1400"
            guard output.contains("mtu \(customMTU)") else {
                throw IntegrationError.assert(
                    msg: "expected MTU \(customMTU) in output, got: \(output)")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testSingleFileMount() async throws {
        let id = "test-single-file-mount"

        let bs = try await bootstrap(id)

        // Create a temp file with known content
        let testContent = "Hello from single file mount!"
        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("config.txt")
        try testContent.write(to: hostFile, atomically: true, encoding: .utf8)

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat", "/etc/myconfig.txt"]
            // Mount a single file using virtiofs share
            config.mounts.append(.share(source: hostFile.path, destination: "/etc/myconfig.txt"))
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to convert output to UTF8")
            }

            guard output == testContent else {
                throw IntegrationError.assert(
                    msg: "expected '\(testContent)', got '\(output)'")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testSingleFileMountReadOnly() async throws {
        let id = "test-single-file-mount-readonly"

        let bs = try await bootstrap(id)

        // Create a temp file with known content
        let testContent = "Read-only file content"
        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("readonly.txt")
        try testContent.write(to: hostFile, atomically: true, encoding: .utf8)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            // Mount a single file as read-only
            config.mounts.append(.share(source: hostFile.path, destination: "/etc/readonly.txt", options: ["ro"]))
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // First verify we can read the file
            let readBuffer = BufferWriter()
            let readExec = try await container.exec("read-file") { config in
                config.arguments = ["cat", "/etc/readonly.txt"]
                config.stdout = readBuffer
            }
            try await readExec.start()
            var status = try await readExec.wait()
            try await readExec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "read status \(status) != 0")
            }

            guard String(data: readBuffer.data, encoding: .utf8) == testContent else {
                throw IntegrationError.assert(msg: "file content mismatch")
            }

            // Now try to write to the file - should fail
            let writeExec = try await container.exec("write-file") { config in
                config.arguments = ["sh", "-c", "echo 'modified' > /etc/readonly.txt"]
            }
            try await writeExec.start()
            status = try await writeExec.wait()
            try await writeExec.delete()

            // Write should fail on a read-only mount
            guard status.exitCode != 0 else {
                throw IntegrationError.assert(msg: "write should have failed on read-only mount")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testSingleFileMountWriteBack() async throws {
        let id = "test-single-file-mount-write-back"

        let bs = try await bootstrap(id)

        // Create a temp file with initial content
        let initialContent = "initial content"
        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("writeable.txt")
        try initialContent.write(to: hostFile, atomically: true, encoding: .utf8)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            // Mount a single file (writable by default)
            config.mounts.append(.share(source: hostFile.path, destination: "/etc/writeable.txt"))
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Write new content from inside the container
            let newContent = "modified from container"
            let writeExec = try await container.exec("write-file") { config in
                config.arguments = ["sh", "-c", "echo -n '\(newContent)' > /etc/writeable.txt"]
            }
            try await writeExec.start()
            let status = try await writeExec.wait()
            try await writeExec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "write status \(status) != 0")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()

            let hostContent = try String(contentsOf: hostFile, encoding: .utf8)
            guard hostContent == newContent else {
                throw IntegrationError.assert(
                    msg: "expected '\(newContent)' on host, got '\(hostContent)'")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testSingleFileMountSymlink() async throws {
        let id = "test-single-file-mount-symlink"

        let bs = try await bootstrap(id)

        // Create a temp directory with a real file and a symlink to it
        let tempDir = FileManager.default.uniqueTemporaryDirectory(create: true)
        let realFile = tempDir.appendingPathComponent("realfile.txt")
        let symlinkFile = tempDir.appendingPathComponent("symlink.txt")

        let initialContent = "content via symlink"
        try initialContent.write(to: realFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            // Mount the symlink (should resolve to real file)
            config.mounts.append(.share(source: symlinkFile.path, destination: "/etc/config.txt"))
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Read the file to verify content
            let readBuffer = BufferWriter()
            let readExec = try await container.exec("read-file") { config in
                config.arguments = ["cat", "/etc/config.txt"]
                config.stdout = readBuffer
            }
            try await readExec.start()
            var status = try await readExec.wait()
            try await readExec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "read status \(status) != 0")
            }

            guard String(data: readBuffer.data, encoding: .utf8) == initialContent else {
                throw IntegrationError.assert(msg: "content mismatch on read")
            }

            // Write new content from container
            let newContent = "modified via symlink mount"
            let writeExec = try await container.exec("write-file") { config in
                config.arguments = ["sh", "-c", "echo -n '\(newContent)' > /etc/config.txt"]
            }
            try await writeExec.start()
            status = try await writeExec.wait()
            try await writeExec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "write status \(status) != 0")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()

            // Verify the REAL file (not symlink) was modified on the host
            let hostContent = try String(contentsOf: realFile, encoding: .utf8)
            guard hostContent == newContent else {
                throw IntegrationError.assert(
                    msg: "expected '\(newContent)' in real file, got '\(hostContent)'")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testRLimitOpenFiles() async throws {
        let id = "test-rlimit-open-files"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sh", "-c", "ulimit -n"]
            config.process.rlimits = [
                LinuxRLimit(kind: .openFiles, hard: 2048, soft: 1024)
            ]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        // ulimit -n returns the soft limit
        guard output == "1024" else {
            throw IntegrationError.assert(msg: "expected soft limit '1024', got '\(output)'")
        }
    }

    func testRLimitMultiple() async throws {
        let id = "test-rlimit-multiple"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            // Read /proc/self/limits to verify multiple rlimits are set
            config.process.arguments = ["cat", "/proc/self/limits"]
            config.process.rlimits = [
                LinuxRLimit(kind: .openFiles, hard: 4096, soft: 2048),
                LinuxRLimit(kind: .stackSize, hard: 16_777_216, soft: 8_388_608),
                LinuxRLimit(kind: .coreFileSize, hard: 0, soft: 0),
            ]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

        // Parse /proc/self/limits and verify the values
        // Format: "Limit Name                Soft Limit           Hard Limit           Units"
        let lines = output.split(separator: "\n")

        // Helper to find and verify a limit line
        func verifyLimit(name: String, expectedSoft: String, expectedHard: String) throws {
            guard let line = lines.first(where: { $0.contains(name) }) else {
                throw IntegrationError.assert(msg: "limit '\(name)' not found in output")
            }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // The line format varies, but soft and hard are typically the last numeric values before units
            guard parts.contains(expectedSoft) && parts.contains(expectedHard) else {
                throw IntegrationError.assert(
                    msg: "limit '\(name)' expected soft=\(expectedSoft) hard=\(expectedHard), got: \(line)")
            }
        }

        try verifyLimit(name: "Max open files", expectedSoft: "2048", expectedHard: "4096")
        try verifyLimit(name: "Max stack size", expectedSoft: "8388608", expectedHard: "16777216")
        try verifyLimit(name: "Max core file size", expectedSoft: "0", expectedHard: "0")
    }

    func testRLimitExec() async throws {
        let id = "test-rlimit-exec"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Exec a process with rlimits set
            let buffer = BufferWriter()
            let exec = try await container.exec("rlimit-exec") { config in
                config.arguments = ["sh", "-c", "ulimit -n"]
                config.rlimits = [
                    LinuxRLimit(kind: .openFiles, hard: 512, soft: 256)
                ]
                config.stdout = buffer
            }

            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec status \(status) != 0")
            }

            guard let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
            }

            guard output == "256" else {
                throw IntegrationError.assert(msg: "expected soft limit '256', got '\(output)'")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testDuplicateVirtiofsMount() async throws {
        let id = "test-duplicate-virtiofs-mount"

        let bs = try await bootstrap(id)

        // Create a temp directory with a file
        let sharedDir = FileManager.default.uniqueTemporaryDirectory(create: true)
        try "shared content".write(to: sharedDir.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            // Mount the same source directory to two different destinations
            config.mounts.append(.share(source: sharedDir.path, destination: "/mnt1"))
            config.mounts.append(.share(source: sharedDir.path, destination: "/mnt2"))
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Verify both mounts work. Read from /mnt1, then /mnt2
            let exec1 = try await container.exec("read-mnt1") { config in
                config.arguments = ["cat", "/mnt1/data.txt"]
                config.stdout = buffer1
            }
            try await exec1.start()
            var status = try await exec1.wait()
            try await exec1.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "read from /mnt1 failed with status \(status)")
            }

            guard String(data: buffer1.data, encoding: .utf8) == "shared content" else {
                throw IntegrationError.assert(msg: "unexpected content from /mnt1")
            }

            let exec2 = try await container.exec("read-mnt2") { config in
                config.arguments = ["cat", "/mnt2/data.txt"]
                config.stdout = buffer2
            }
            try await exec2.start()
            status = try await exec2.wait()
            try await exec2.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "read from /mnt2 failed with status \(status)")
            }

            guard String(data: buffer2.data, encoding: .utf8) == "shared content" else {
                throw IntegrationError.assert(msg: "unexpected content from /mnt2")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testDuplicateVirtiofsMountViaSymlink() async throws {
        let id = "test-duplicate-virtiofs-mount-symlink"

        let bs = try await bootstrap(id)

        // Create a temp directory with a file, and a symlink to the same directory
        let tempDir = FileManager.default.uniqueTemporaryDirectory(create: true)
        let realDir = tempDir.appendingPathComponent("realdir")
        let symlinkDir = tempDir.appendingPathComponent("symlinkdir")

        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try "symlink test content".write(to: realDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.mounts.append(.share(source: realDir.path, destination: "/mnt1"))
            config.mounts.append(.share(source: symlinkDir.path, destination: "/mnt2"))
            config.bootLog = bs.bootLog
        }

        do {
            // This should succeed as the symlink should resolve to the same directory
            try await container.create()
            try await container.start()

            let exec1 = try await container.exec("read-mnt1") { config in
                config.arguments = ["cat", "/mnt1/file.txt"]
                config.stdout = buffer1
            }
            try await exec1.start()
            var status = try await exec1.wait()
            try await exec1.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "read from /mnt1 failed with status \(status)")
            }

            guard String(data: buffer1.data, encoding: .utf8) == "symlink test content" else {
                throw IntegrationError.assert(msg: "unexpected content from /mnt1")
            }

            // Verify mount via symlink works now
            let exec2 = try await container.exec("read-mnt2") { config in
                config.arguments = ["cat", "/mnt2/file.txt"]
                config.stdout = buffer2
            }
            try await exec2.start()
            status = try await exec2.wait()
            try await exec2.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "read from /mnt2 failed with status \(status)")
            }

            guard String(data: buffer2.data, encoding: .utf8) == "symlink test content" else {
                throw IntegrationError.assert(msg: "unexpected content from /mnt2")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testWritableLayer() async throws {
        let id = "test-writable-layer"

        let bs = try await bootstrap(id)

        let writableLayerPath = Self.testDir.appending(component: "\(id)-writable.ext4")
        try? FileManager.default.removeItem(at: writableLayerPath)
        let filesystem = try EXT4.Formatter(FilePath(writableLayerPath.absolutePath()), minDiskSize: 512.mib())
        try filesystem.close()
        let writableLayer = Mount.block(
            format: "ext4",
            source: writableLayerPath.absolutePath(),
            destination: "/",
            options: []
        )

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, writableLayer: writableLayer, vmm: bs.vmm) { config in
            // Write a file, then read it back to verify writes work
            config.process.arguments = ["/bin/sh", "-c", "echo 'writable layer test' > /tmp/testfile && cat /tmp/testfile"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process failed with status \(status)")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "writable layer test" else {
            throw IntegrationError.assert(msg: "unexpected output: \(output)")
        }
    }

    func testWritableLayerPreservesLowerLayer() async throws {
        let id = "test-writable-layer-preserves-lower"

        let bs = try await bootstrap(id)

        let writableLayerPath = Self.testDir.appending(component: "\(id)-writable.ext4")
        try? FileManager.default.removeItem(at: writableLayerPath)
        let filesystem = try EXT4.Formatter(FilePath(writableLayerPath.absolutePath()), minDiskSize: 512.mib())
        try filesystem.close()
        let writableLayer = Mount.block(
            format: "ext4",
            source: writableLayerPath.absolutePath(),
            destination: "/",
            options: []
        )

        // Get the size of /bin/sh before any modifications
        let buffer1 = BufferWriter()
        let container1 = try LinuxContainer("\(id)-1", rootfs: bs.rootfs, writableLayer: writableLayer, vmm: bs.vmm) { config in
            // Modify a file in /bin. This should go in the writable layer.
            config.process.arguments = ["/bin/sh", "-c", "ls -la /bin/sh && echo 'modified' > /bin/test-file"]
            config.process.stdout = buffer1
            config.bootLog = bs.bootLog
        }

        try await container1.create()
        try await container1.start()
        let status1 = try await container1.wait()
        try await container1.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "first container failed with status \(status1)")
        }

        // Now run a second container with the SAME rootfs but without the writable layer
        // The /bin/test-file should NOT exist because it was written to the writable layer
        let buffer2 = BufferWriter()
        let container2 = try LinuxContainer("\(id)-2", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sh", "-c", "test -f /bin/test-file && echo 'exists' || echo 'not-exists'"]
            config.process.stdout = buffer2
            config.bootLog = bs.bootLog
        }

        try await container2.create()
        try await container2.start()
        let status2 = try await container2.wait()
        try await container2.stop()

        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "second container failed with status \(status2)")
        }

        guard let output2 = String(data: buffer2.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard output2.trimmingCharacters(in: .whitespacesAndNewlines) == "not-exists" else {
            throw IntegrationError.assert(msg: "expected 'not-exists' but got: \(output2)")
        }
    }

    func testWritableLayerReadsFromLower() async throws {
        let id = "test-writable-layer-reads-lower"

        let bs = try await bootstrap(id)

        let writableLayerPath = Self.testDir.appending(component: "\(id)-writable.ext4")
        try? FileManager.default.removeItem(at: writableLayerPath)
        let filesystem = try EXT4.Formatter(FilePath(writableLayerPath.absolutePath()), minDiskSize: 512.mib())
        try filesystem.close()
        let writableLayer = Mount.block(
            format: "ext4",
            source: writableLayerPath.absolutePath(),
            destination: "/",
            options: []
        )

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, writableLayer: writableLayer, vmm: bs.vmm) { config in
            config.process.arguments = ["head", "-1", "/etc/passwd"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process failed with status \(status)")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        // Alpine's first line of /etc/passwd should be root
        guard output.hasPrefix("root:") else {
            throw IntegrationError.assert(msg: "expected /etc/passwd to start with 'root:', got: \(output)")
        }
    }

    func testWritableLayerWithReadOnlyLower() async throws {
        let id = "test-writable-layer-ro-lower"

        let bs = try await bootstrap(id)
        var rootfs = bs.rootfs
        rootfs.options.append("ro")

        let writableLayerPath = Self.testDir.appending(component: "\(id)-writable.ext4")
        try? FileManager.default.removeItem(at: writableLayerPath)
        let filesystem = try EXT4.Formatter(FilePath(writableLayerPath.absolutePath()), minDiskSize: 512.mib())
        try filesystem.close()
        let writableLayer = Mount.block(
            format: "ext4",
            source: writableLayerPath.absolutePath(),
            destination: "/",
            options: []
        )

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: rootfs, writableLayer: writableLayer, vmm: bs.vmm) { config in
            // Even though lower layer is ro, writes should succeed via overlay
            config.process.arguments = ["/bin/sh", "-c", "echo 'overlay write test' > /tmp/test && cat /tmp/test"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process failed with status \(status)")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "overlay write test" else {
            throw IntegrationError.assert(msg: "unexpected output: \(output)")
        }
    }

    func testWritableLayerSize() async throws {
        let id = "test-writable-layer-size"

        let bs = try await bootstrap(id)

        // Create a 1 GiB writable layer
        let expectedSizeBytes: UInt64 = 1.gib()
        let writableLayerPath = Self.testDir.appending(component: "\(id)-writable.ext4")
        try? FileManager.default.removeItem(at: writableLayerPath)
        let filesystem = try EXT4.Formatter(FilePath(writableLayerPath.absolutePath()), minDiskSize: expectedSizeBytes)
        try filesystem.close()
        let writableLayer = Mount.block(
            format: "ext4",
            source: writableLayerPath.absolutePath(),
            destination: "/",
            options: []
        )

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, writableLayer: writableLayer, vmm: bs.vmm) { config in
            // Use df to check the available space on the root filesystem
            // The overlay will report the size of the upper layer's backing store
            config.process.arguments = ["/bin/sh", "-c", "df -B1 / | tail -1 | awk '{print $2}'"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process failed with status \(status)")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard let reportedSize = UInt64(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw IntegrationError.assert(msg: "failed to parse df output as UInt64: \(output)")
        }

        // The reported size should be close to our expected size (within 10%)
        let minExpected: UInt64 = (expectedSizeBytes * 90) / 100
        let maxExpected: UInt64 = (expectedSizeBytes * 110) / 100

        guard reportedSize >= minExpected && reportedSize <= maxExpected else {
            throw IntegrationError.assert(msg: "expected size ~\(expectedSizeBytes) bytes, but df reported \(reportedSize) bytes")
        }
    }

    func testWritableLayerWithDNSAndHosts() async throws {
        let id = "test-writable-layer-dns-hosts"

        let bs = try await bootstrap(id)

        let writableLayerPath = Self.testDir.appending(component: "\(id)-writable.ext4")
        try? FileManager.default.removeItem(at: writableLayerPath)
        let filesystem = try EXT4.Formatter(FilePath(writableLayerPath.absolutePath()), minDiskSize: 512.mib())
        try filesystem.close()
        let writableLayer = Mount.block(
            format: "ext4",
            source: writableLayerPath.absolutePath(),
            destination: "/",
            options: []
        )

        let buffer = BufferWriter()
        let dnsEntry = "8.8.8.8"
        let hostsEntry = Hosts.Entry.localHostIPV4(comment: "WritableLayerTest")
        let container = try LinuxContainer(id, rootfs: bs.rootfs, writableLayer: writableLayer, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sh", "-c", "cat /etc/resolv.conf && echo '---' && cat /etc/hosts"]
            config.process.stdout = buffer
            config.dns = DNS(nameservers: [dnsEntry])
            config.hosts = Hosts(entries: [hostsEntry])
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process failed with status \(status)")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard output.contains(dnsEntry) else {
            throw IntegrationError.assert(msg: "expected /etc/resolv.conf to contain \(dnsEntry), got: \(output)")
        }

        guard output.contains("WritableLayerTest") else {
            throw IntegrationError.assert(msg: "expected /etc/hosts to contain our entry, got: \(output)")
        }
    }

    func testUseInitBasic() async throws {
        let id = "test-use-init-basic"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/echo", "hello from init"]
            config.process.stdout = buffer
            config.useInit = true
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard String(data: buffer.data, encoding: .utf8) == "hello from init\n" else {
            throw IntegrationError.assert(
                msg: "expected 'hello from init', got '\(String(data: buffer.data, encoding: .utf8) ?? "nil")'")
        }
    }

    func testUseInitExitCodePropagation() async throws {
        let id = "test-use-init-exit-code"

        let bs = try await bootstrap(id)

        // Test exit code 0
        var container = try LinuxContainer("\(id)-success", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/true"]
            config.useInit = true
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()
        var status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "expected exit code 0, got \(status.exitCode)")
        }

        // Test non-zero exit code
        container = try LinuxContainer("\(id)-failure", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/false"]
            config.useInit = true
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()
        status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 1 else {
            throw IntegrationError.assert(msg: "expected exit code 1, got \(status.exitCode)")
        }

        // Test custom exit code
        container = try LinuxContainer("\(id)-custom", rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sh", "-c", "exit 42"]
            config.useInit = true
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()
        status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 42 else {
            throw IntegrationError.assert(msg: "expected exit code 42, got \(status.exitCode)")
        }
    }

    func testUseInitSignalForwarding() async throws {
        let id = "test-use-init-signal"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "300"]
            config.useInit = true
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            try await Task.sleep(for: .milliseconds(100))

            try await container.kill(SIGTERM)

            let status = try await container.wait(timeoutInSeconds: 5)
            try await container.stop()

            // SIGTERM should result in exit code 128 + 15 = 143
            guard status.exitCode == 143 else {
                throw IntegrationError.assert(msg: "expected exit code 143 (SIGTERM), got \(status.exitCode)")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testUseInitZombieReaping() async throws {
        let id = "test-use-init-zombie-reaping"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            // This script creates an orphaned process that init must reap.
            // The subshell exits immediately, orphaning the sleep process.
            // Init should reap it when it exits.
            config.process.arguments = [
                "/bin/sh", "-c",
                """
                # Create orphans: subshell exits before its children
                (/bin/sleep 0.1 &)
                (/bin/sleep 0.1 &)
                # Wait for orphans to complete
                /bin/sleep 0.3
                # Check for zombie processes (Z state)
                zombies=$(ps -eo stat 2>/dev/null | grep -c '^Z' || echo 0)
                echo "zombie_count:$zombies"
                """,
            ]
            config.process.stdout = buffer
            config.useInit = true
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to convert output to UTF8")
            }

            // Should report 0 zombies
            guard output.contains("zombie_count:0") else {
                throw IntegrationError.assert(msg: "expected zero zombies, got: \(output)")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testUseInitWithTerminal() async throws {
        let id = "test-use-init-terminal"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sh", "-c", "tty && echo 'has tty'"]
            config.process.terminal = true
            config.process.stdout = buffer
            config.useInit = true
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert output to UTF8")
        }

        guard output.contains("has tty") else {
            throw IntegrationError.assert(msg: "expected 'has tty' in output, got: \(output)")
        }
    }

    func testUseInitWithStdin() async throws {
        let id = "test-use-init-stdin"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat"]
            config.process.stdin = StdinBuffer(data: "input through init\n".data(using: .utf8)!)
            config.process.stdout = buffer
            config.useInit = true
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard String(data: buffer.data, encoding: .utf8) == "input through init\n" else {
            throw IntegrationError.assert(
                msg: "expected 'input through init', got '\(String(data: buffer.data, encoding: .utf8) ?? "nil")'")
        }
    }

    @available(macOS 26.0, *)
    func testNetworkingDisabled() async throws {
        let id = "test-networking-disabled"
        let bs = try await bootstrap(id)

        let network = try VmnetNetwork()
        var manager = try ContainerManager(vmm: bs.vmm, network: network)
        defer {
            try? manager.delete(id)
        }

        let buffer = BufferWriter()
        let container = try await manager.create(
            id,
            image: bs.image,
            rootfs: bs.rootfs,
            networking: false
        ) { config in
            config.process.arguments = ["ls", "-1", "/sys/class/net/"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "ls /sys/class/net/ failed with status \(status)")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to convert output to UTF8")
            }

            // With networking disabled check we don't have an eth0.
            let interfaces = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            guard !interfaces.contains("eth0") else {
                throw IntegrationError.assert(
                    msg: "expected no 'eth0' interface")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    @available(macOS 26.0, *)
    func testNetworkingEnabled() async throws {
        let id = "test-networking-enabled"
        let bs = try await bootstrap(id)

        let network = try VmnetNetwork()
        var manager = try ContainerManager(vmm: bs.vmm, network: network)
        defer {
            try? manager.delete(id)
        }

        let buffer = BufferWriter()
        let container = try await manager.create(
            id,
            image: bs.image,
            rootfs: bs.rootfs
        ) { config in
            config.process.arguments = ["ls", "-1", "/sys/class/net/"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "ls /sys/class/net/ failed with status \(status)")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to convert output to UTF8")
            }

            // With networking enabled (default), eth0 should be present alongside lo
            let interfaces = Set(
                output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            )
            guard interfaces.contains("lo") else {
                throw IntegrationError.assert(msg: "expected 'lo' interface, got: \(interfaces)")
            }
            guard interfaces.contains("eth0") else {
                throw IntegrationError.assert(msg: "expected 'eth0' interface, got: \(interfaces)")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testSysctl() async throws {
        let id = "test-container-sysctl"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.sysctl = [
                "net.core.somaxconn": "4096"
            ]
            config.process.arguments = ["cat", "/proc/sys/net/core/somaxconn"]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard output == "4096" else {
                throw IntegrationError.assert(
                    msg: "sysctl net.core.somaxconn should be '4096', got '\(output ?? "nil")'")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testSysctlMultiple() async throws {
        let id = "test-container-sysctl-multiple"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.sysctl = [
                "net.core.somaxconn": "2048",
                "net.ipv4.ip_forward": "1",
            ]
            config.process.arguments = [
                "/bin/sh", "-c",
                "cat /proc/sys/net/core/somaxconn && cat /proc/sys/net/ipv4/ip_forward",
            ]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }

            let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = output?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines == ["2048", "1"] else {
                throw IntegrationError.assert(
                    msg: "expected sysctls ['2048', '1'], got '\(output ?? "nil")'")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testNoNewPrivileges() async throws {
        let id = "test-no-new-privileges"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat", "/proc/self/status"]
            config.process.noNewPrivileges = true
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

        // /proc/self/status contains "NoNewPrivs:\t1" when the bit is set
        guard output.contains("NoNewPrivs:\t1") else {
            throw IntegrationError.assert(msg: "expected NoNewPrivs to be 1, got: \(output)")
        }
    }

    func testNoNewPrivilegesDisabled() async throws {
        let id = "test-no-new-privileges-disabled"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["cat", "/proc/self/status"]
            // noNewPrivileges defaults to false
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
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

        // When noNewPrivileges is not set, NoNewPrivs should be 0
        guard output.contains("NoNewPrivs:\t0") else {
            throw IntegrationError.assert(msg: "expected NoNewPrivs to be 0, got: \(output)")
        }
    }

    func testWorkingDirCreated() async throws {
        let id = "test-working-dir-created"
        let bs = try await bootstrap(id)

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/pwd"]
            config.process.workingDirectory = "/does/not/exist"
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "process with non-existent workingDir failed: \(status)")
            }

            guard let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to read stdout")
            }

            guard output == "/does/not/exist" else {
                throw IntegrationError.assert(msg: "expected cwd '/does/not/exist', got '\(output)'")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testWorkingDirExecCreated() async throws {
        let id = "test-working-dir-exec-created"
        let bs = try await bootstrap(id)

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/sleep", "1000"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            let buffer = BufferWriter()
            let exec = try await container.exec("cwd-exec") { config in
                config.arguments = ["/bin/pwd"]
                config.workingDirectory = "/a/b/c/d"
                config.stdout = buffer
            }

            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec with non-existent workingDir failed: \(status)")
            }

            guard let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to read stdout")
            }

            guard output == "/a/b/c/d" else {
                throw IntegrationError.assert(msg: "expected cwd '/a/b/c/d', got '\(output)'")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testNoNewPrivilegesExec() async throws {
        let id = "test-no-new-privileges-exec"

        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.bootLog = bs.bootLog
        }

        do {
            try await container.create()
            try await container.start()

            // Exec a process with noNewPrivileges set
            let buffer = BufferWriter()
            let exec = try await container.exec("nnp-exec") { config in
                config.arguments = ["cat", "/proc/self/status"]
                config.noNewPrivileges = true
                config.stdout = buffer
            }

            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "exec status \(status) != 0")
            }

            guard let output = String(data: buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
            }

            guard output.contains("NoNewPrivs:\t1") else {
                throw IntegrationError.assert(msg: "expected NoNewPrivs to be 1 in exec, got: \(output)")
            }

            try await container.kill(SIGKILL)
            try await container.wait()
            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    // Verify that mounts are sorted by destination path depth so that a
    // higher-level mount (e.g. /mnt) doesn't shadow a deeper mount
    // (e.g. /mnt/deep/nested). Both directories are separate virtiofs
    // shares; the sort ensures /mnt is mounted first and /mnt/deep/nested
    // on top of it.
    func testMountsSortedByDepth() async throws {
        let id = "test-mount-sort-depth"

        let bs = try await bootstrap(id)
        let buffer = BufferWriter()

        // Create two separate mount directories with distinct files.
        let deepDir = FileManager.default.uniqueTemporaryDirectory(create: true)
        try "deep-content".write(to: deepDir.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

        let shallowDir = FileManager.default.uniqueTemporaryDirectory(create: true)
        try "shallow-content".write(to: shallowDir.appendingPathComponent("shallow.txt"), atomically: true, encoding: .utf8)

        // Add deeper mount first, then shallower mount. Without sorting the
        // shallower mount would shadow the deeper one.
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["/bin/cat", "/mnt/deep/nested/deep.txt"]
            config.mounts.append(.share(source: deepDir.path, destination: "/mnt/deep/nested"))
            config.mounts.append(.share(source: shallowDir.path, destination: "/mnt"))
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        let value = String(data: buffer.data, encoding: .utf8)
        guard value == "deep-content" else {
            throw IntegrationError.assert(
                msg: "expected 'deep-content' but got '\(value ?? "<nil>")'")
        }
    }
}
