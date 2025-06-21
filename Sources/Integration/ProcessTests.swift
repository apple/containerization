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
import ContainerizationOCI
import ContainerizationOS
import Crypto
import Foundation
import Logging

extension IntegrationSuite {
    func testProcessTrue() async throws {
        let id = "test-process-true"

        let bs = try await bootstrap()
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/bin/true"]

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
    }

    func testProcessFalse() async throws {
        let id = "test-process-false"

        let bs = try await bootstrap()
        let container = LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm)
        container.arguments = ["/bin/false"]

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status == 1 else {
            throw IntegrationError.assert(msg: "process status \(status) != 1")
        }
    }

    final class BufferWriter: Writer {
        nonisolated(unsafe) var data = Data()

        func write(_ data: Data) throws {
            guard data.count > 0 else {
                return
            }
            self.data.append(data)
        }
    }

    func testProcessEchoHi() async throws {
        let id = "test-process-echo-hi"
        let bs = try await bootstrap()
        let container = LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm)
        container.arguments = ["/bin/echo", "hi"]

        let buffer = BufferWriter()
        container.stdout = buffer

        do {
            try await container.create()
            try await container.start()

            let status = try await container.wait()
            try await container.stop()

            guard status == 0 else {
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
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/bin/sleep", "1000"]

        do {
            try await container.create()
            try await container.start()

            let execConfig = ContainerizationOCI.Process(
                args: ["/bin/true"],
                env: ["PATH=\(LinuxContainer.defaultPath)"]
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0...80 {
                    let exec = try await container.exec(
                        "exec-\(i)",
                        configuration: execConfig
                    )

                    group.addTask {
                        try await exec.start()
                        let status = try await exec.wait()
                        if status != 0 {
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
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/bin/sleep", "1000"]

        do {
            try await container.create()
            try await container.start()

            let baseExecConfig = ContainerizationOCI.Process(
                args: ["sh", "-c", "dd if=/dev/random of=/tmp/bytes bs=1M count=20 status=none ; sha256sum /tmp/bytes"],
                env: ["PATH=\(LinuxContainer.defaultPath)"]
            )
            let buffer = BufferWriter()
            let exec = try await container.exec(
                "expected-value",
                configuration: baseExecConfig,
                stdout: buffer,
            )
            try await exec.start()
            let status = try await exec.wait()
            if status != 0 {
                throw IntegrationError.assert(msg: "process status \(status) != 0")
            }
            let output = String(data: buffer.data, encoding: .utf8)!
            let expected = String(output.split(separator: " ").first!)
            try await withThrowingTaskGroup(of: Void.self) { group in
                let execConfig = ContainerizationOCI.Process(
                    args: ["cat", "/tmp/bytes"],
                    env: ["PATH=\(LinuxContainer.defaultPath)"]
                )
                for i in 0...80 {
                    let idx = i
                    group.addTask {
                        let buffer = BufferWriter()
                        let exec = try await container.exec(
                            "exec-\(idx)",
                            configuration: execConfig,
                            stdout: buffer,
                        )
                        try await exec.start()

                        let status = try await exec.wait()
                        if status != 0 {
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
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/usr/bin/id"]
        container.user = .init(uid: 1, gid: 1, additionalGids: [1])

        let buffer = BufferWriter()
        container.stdout = buffer

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
        let expected = "uid=1(bin) gid=1(bin) groups=1(bin)"

        guard String(data: buffer.data, encoding: .utf8) == "\(expected)\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }

    // Ensure if we ask for a terminal we set TERM.
    func testProcessTtyEnvvar() async throws {
        let id = "test-process-tty-envvar"

        let bs = try await bootstrap()
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["env"]
        container.terminal = true

        let buffer = BufferWriter()
        container.stdout = buffer

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
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["env"]
        container.user = .init(uid: 0, gid: 0)

        let buffer = BufferWriter()
        container.stdout = buffer

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

        let homeEnvvar = "HOME=/root"
        guard str.contains(homeEnvvar) else {
            throw IntegrationError.assert(
                msg: "process should have HOME environment variable defined")
        }
    }

    func testProcessCustomHomeEnvvar() async throws {
        let id = "test-process-custom-home-envvar"

        let bs = try await bootstrap()
        let container = LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm)

        let customHomeEnvvar = "HOME=/tmp/custom/home"
        container.environment = [customHomeEnvvar]
        container.arguments = ["sh", "-c", "echo HOME=$HOME"]
        container.user = .init(uid: 0, gid: 0)

        let buffer = BufferWriter()
        container.stdout = buffer

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
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
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/bin/hostname"]
        container.hostname = "foo-bar"

        let buffer = BufferWriter()
        container.stdout = buffer

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
        let expected = "foo-bar"

        guard String(data: buffer.data, encoding: .utf8) == "\(expected)\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }
}
