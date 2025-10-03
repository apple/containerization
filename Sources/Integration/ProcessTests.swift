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
                print("\(status)")
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
}
