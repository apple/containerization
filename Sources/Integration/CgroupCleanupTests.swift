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
import ContainerizationError
import Foundation

extension IntegrationSuite {
    /// Domain cgroups provide the control for threaded-cgroup cleanup.
    func testEmptyDomainCgroupCleanup() async throws {
        let id = "test-cgroup-cleanup-domain-empty"
        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = .allCapabilities
            config.bootLog = bs.bootLog
            config.process.arguments = [
                "/bin/sh", "-ec",
                """
                for path in /sys/fs/cgroup/nested /sys/fs/cgroup/nested/child; do
                    mkdir "$path"
                    test "$(cat "$path/cgroup.type")" = 'domain'
                    threads=$(cat "$path/cgroup.threads")
                    test -z "$threads"
                done
                """,
            ]
        }

        try await container.create()
        let vm = try await container.withVirtualMachineInstance { $0 }
        do {
            try await withDeadline(seconds: 60, "cgroup container start") { try await container.start() }

            let status = try await container.wait(timeoutInSeconds: 30)
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "cgroup setup failed: \(status)")
            }

            let connection = try await vm.dialAgent()
            do {
                guard let guest = connection as? Vminitd else {
                    throw IntegrationError.assert(msg: "expected vminitd guest agent")
                }
                let path = "/sys/fs/cgroup/container/\(id)"
                _ = try await guest.stat(root: "/", path: "\(path)/nested/child")
                try await connection.close()
            } catch {
                try? await vm.stop()
                try? await connection.close()
                throw error
            }

            try await withDeadline(seconds: 30, "empty cgroup container stop") { try await container.stop() }
            guard case .stopped = vm.state else {
                throw IntegrationError.assert(msg: "VM still running after cgroup test cleanup")
            }
        } catch {
            if vm.state != .stopped {
                try? await vm.stop()
            }
            throw error
        }
    }

    /// Threaded cgroups must remain removable after the init process exits.
    func testEmptyThreadedCgroupCleanup() async throws {
        let id = "test-cgroup-cleanup-threaded-empty"
        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = .allCapabilities
            config.bootLog = bs.bootLog
            config.process.arguments = [
                "/bin/sh", "-ec",
                """
                for path in /sys/fs/cgroup/nested /sys/fs/cgroup/nested/child; do
                    mkdir "$path"
                    echo threaded > "$path/cgroup.type"
                    test "$(cat "$path/cgroup.type")" = 'threaded'
                    threads=$(cat "$path/cgroup.threads")
                    test -z "$threads"
                done
                """,
            ]
        }

        try await container.create()
        let vm = try await container.withVirtualMachineInstance { $0 }
        do {
            try await withDeadline(seconds: 60, "cgroup container start") { try await container.start() }

            let status = try await container.wait(timeoutInSeconds: 30)
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "cgroup setup failed: \(status)")
            }

            let connection = try await vm.dialAgent()
            do {
                guard let guest = connection as? Vminitd else {
                    throw IntegrationError.assert(msg: "expected vminitd guest agent")
                }
                let path = "/sys/fs/cgroup/container/\(id)"
                _ = try await guest.stat(root: "/", path: "\(path)/nested/child")
                try await connection.close()
            } catch {
                try? await vm.stop()
                try? await connection.close()
                throw error
            }

            try await withDeadline(seconds: 30, "empty cgroup container stop") { try await container.stop() }
            guard case .stopped = vm.state else {
                throw IntegrationError.assert(msg: "VM still running after cgroup test cleanup")
            }
        } catch {
            if vm.state != .stopped {
                try? await vm.stop()
            }
            throw error
        }
    }

    /// Delete through the guest before Stop's VM-wide SIGKILL can hide a failed subtree kill.
    func testLiveDomainCgroupCleanup() async throws {
        let id = "test-cgroup-cleanup-domain-live"
        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = .allCapabilities
            config.bootLog = bs.bootLog
            config.process.arguments = [
                "/bin/sh", "-ec",
                """
                for path in /sys/fs/cgroup/nested /sys/fs/cgroup/nested/child; do
                    mkdir "$path"
                    test "$(cat "$path/cgroup.type")" = 'domain'
                    threads=$(cat "$path/cgroup.threads")
                    test -z "$threads"
                done
                trap '' TERM
                sleep 300 &
                pid=$!
                echo "$pid" > /sys/fs/cgroup/nested/child/cgroup.procs
                echo "$pid" > /tmp/descendant.pid
                wait "$pid"
                """,
            ]
        }

        try await container.create()
        let vm = try await container.withVirtualMachineInstance { $0 }
        do {
            try await withDeadline(seconds: 60, "cgroup container start") { try await container.start() }

            let probe = try await container.exec("ready") { config in
                config.arguments = [
                    "/bin/sh", "-ec",
                    """
                    i=0
                    while [ ! -s /tmp/descendant.pid ]; do
                        i=$((i + 1)); test "$i" -lt 100; sleep 0.1
                    done
                    pid=$(cat /tmp/descendant.pid)
                    kill -TERM "$pid"
                    sleep 0.1
                    kill -0 "$pid"
                    threads=$(cat /sys/fs/cgroup/nested/child/cgroup.threads)
                    test -n "$threads"
                    """,
                ]
            }
            try await probe.start()
            let status = try await probe.wait(timeoutInSeconds: 30)
            try await probe.delete()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "nested descendant did not survive SIGTERM: \(status)")
            }

            let connection = try await vm.dialAgent()
            do {
                guard let guest = connection as? Vminitd else {
                    throw IntegrationError.assert(msg: "expected vminitd guest agent")
                }
                let path = "/sys/fs/cgroup/container/\(id)"
                _ = try await guest.stat(root: "/", path: "\(path)/nested/child")

                try await withDeadline(seconds: 30, "forced cgroup cleanup") {
                    try await guest.deleteProcess(id: id, containerID: id)
                }
                do {
                    _ = try await guest.stat(root: "/", path: path)
                    throw IntegrationError.assert(msg: "container cgroup still exists after deletion")
                } catch let error as ContainerizationError where error.code == .notFound {
                }
                guard case .running = vm.state else {
                    throw IntegrationError.assert(msg: "VM stopped before cgroup cleanup was verified")
                }
                try await connection.close()
            } catch {
                try? await vm.stop()
                try? await connection.close()
                throw error
            }

            try await vm.stop()
            guard case .stopped = vm.state else {
                throw IntegrationError.assert(msg: "VM still running after cgroup test cleanup")
            }
        } catch {
            if vm.state != .stopped {
                try? await vm.stop()
            }
            throw error
        }
    }

    /// Delete through the guest before Stop's VM-wide SIGKILL can hide a failed subtree kill.
    func testLiveThreadedCgroupCleanup() async throws {
        let id = "test-cgroup-cleanup-threaded-live"
        let bs = try await bootstrap(id)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.capabilities = .allCapabilities
            config.bootLog = bs.bootLog
            config.process.arguments = [
                "/bin/sh", "-ec",
                """
                for path in /sys/fs/cgroup/nested /sys/fs/cgroup/nested/child; do
                    mkdir "$path"
                    echo threaded > "$path/cgroup.type"
                    test "$(cat "$path/cgroup.type")" = 'threaded'
                    threads=$(cat "$path/cgroup.threads")
                    test -z "$threads"
                done
                trap '' TERM
                sleep 300 &
                pid=$!
                echo "$pid" > /sys/fs/cgroup/nested/child/cgroup.procs
                echo "$pid" > /tmp/descendant.pid
                wait "$pid"
                """,
            ]
        }

        try await container.create()
        let vm = try await container.withVirtualMachineInstance { $0 }
        do {
            try await withDeadline(seconds: 60, "cgroup container start") { try await container.start() }

            let probe = try await container.exec("ready") { config in
                config.arguments = [
                    "/bin/sh", "-ec",
                    """
                    i=0
                    while [ ! -s /tmp/descendant.pid ]; do
                        i=$((i + 1)); test "$i" -lt 100; sleep 0.1
                    done
                    pid=$(cat /tmp/descendant.pid)
                    kill -TERM "$pid"
                    sleep 0.1
                    kill -0 "$pid"
                    threads=$(cat /sys/fs/cgroup/nested/child/cgroup.threads)
                    test -n "$threads"
                    """,
                ]
            }
            try await probe.start()
            let status = try await probe.wait(timeoutInSeconds: 30)
            try await probe.delete()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "nested descendant did not survive SIGTERM: \(status)")
            }

            let connection = try await vm.dialAgent()
            do {
                guard let guest = connection as? Vminitd else {
                    throw IntegrationError.assert(msg: "expected vminitd guest agent")
                }
                let path = "/sys/fs/cgroup/container/\(id)"
                _ = try await guest.stat(root: "/", path: "\(path)/nested/child")

                try await withDeadline(seconds: 30, "forced cgroup cleanup") {
                    try await guest.deleteProcess(id: id, containerID: id)
                }
                do {
                    _ = try await guest.stat(root: "/", path: path)
                    throw IntegrationError.assert(msg: "container cgroup still exists after deletion")
                } catch let error as ContainerizationError where error.code == .notFound {
                }
                guard case .running = vm.state else {
                    throw IntegrationError.assert(msg: "VM stopped before cgroup cleanup was verified")
                }
                try await connection.close()
            } catch {
                try? await vm.stop()
                try? await connection.close()
                throw error
            }

            try await vm.stop()
            guard case .stopped = vm.state else {
                throw IntegrationError.assert(msg: "VM still running after cgroup test cleanup")
            }
        } catch {
            if vm.state != .stopped {
                try? await vm.stop()
            }
            throw error
        }
    }
}

