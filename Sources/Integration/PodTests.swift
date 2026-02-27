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
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging

extension IntegrationSuite {
    /// Clone a rootfs mount to a new location for use by a container in a pod
    private func cloneRootfs(_ rootfs: Containerization.Mount, testID: String, containerID: String) throws -> Containerization.Mount {
        let clonePath = Self.testDir.appending(component: "\(testID)-\(containerID).ext4").absolutePath()
        try? FileManager.default.removeItem(atPath: clonePath)
        return try rootfs.clone(to: clonePath)
    }

    func testPodSingleContainer() async throws {
        let id = "test-pod-single-container"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/true"]
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
    }

    func testPodMultipleContainers() async throws {
        let id = "test-pod-multiple-containers"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/true"]
        }

        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/echo", "hello"]
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 status \(status1) != 0")
        }

        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 status \(status2) != 0")
        }
    }

    func testPodContainerOutput() async throws {
        let id = "test-pod-container-output"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/echo", "hello from pod"]
            config.process.stdout = buffer
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard String(data: buffer.data, encoding: .utf8) == "hello from pod\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout 'hello from pod' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }

    func testPodConcurrentContainers() async throws {
        let id = "test-pod-concurrent-containers"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        // Add 5 containers
        for i in 0..<5 {
            try await pod.addContainer("container\(i)", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container\(i)")) { config in
                config.process.arguments = ["/bin/sleep", "1"]
            }
        }

        try await pod.create()

        // Start all containers concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    try await pod.startContainer("container\(i)")
                }
            }
            try await group.waitForAll()
        }

        // Wait for all containers concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let status = try await pod.waitContainer("container\(i)")
                    if status.exitCode != 0 {
                        throw IntegrationError.assert(msg: "container\(i) status \(status) != 0")
                    }
                }
            }
            try await group.waitForAll()
        }

        try await pod.stop()
    }

    func testPodExecInContainer() async throws {
        let id = "test-pod-exec-in-container"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/sleep", "100"]
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let buffer = BufferWriter()
        let exec = try await pod.execInContainer("container1", processID: "exec1") { config in
            config.arguments = ["/bin/echo", "exec test"]
            config.stdout = buffer
        }

        try await exec.start()
        let status = try await exec.wait()
        try await exec.delete()

        try await pod.killContainer("container1", signal: SIGKILL)
        try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "exec status \(status) != 0")
        }

        guard String(data: buffer.data, encoding: .utf8) == "exec test\n" else {
            throw IntegrationError.assert(
                msg: "exec should have returned 'exec test' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }

    func testPodExecInContainerEnv() async throws {
        let id = "test-pod-exec-in-container-env"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/sleep", "100"]
            config.process.environmentVariables.append("MY_VAR=hello_from_container")
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let buffer = BufferWriter()
        let exec = try await pod.execInContainer("container1", processID: "exec1") { config in
            config.arguments = ["/bin/sh", "-c", "printenv MY_VAR"]
            config.stdout = buffer
        }

        try await exec.start()
        let status = try await exec.wait()
        try await exec.delete()

        try await pod.killContainer("container1", signal: SIGKILL)
        try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "exec env status \(status) != 0")
        }

        guard String(data: buffer.data, encoding: .utf8) == "hello_from_container\n" else {
            throw IntegrationError.assert(
                msg: "exec should have inherited container env MY_VAR=hello_from_container, got '\(String(data: buffer.data, encoding: .utf8) ?? "nil")'")
        }
    }

    func testPodContainerHostname() async throws {
        let id = "test-pod-container-hostname"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/hostname"]
            config.hostname = "my-pod-container"
            config.process.stdout = buffer
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard String(data: buffer.data, encoding: .utf8) == "my-pod-container\n" else {
            throw IntegrationError.assert(
                msg: "hostname should be 'my-pod-container' != '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }

    func testPodContainerHostnameDefaultsToContainerID() async throws {
        let id = "test-pod-container-hostname-default"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/hostname"]
            config.process.stdout = buffer
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard String(data: buffer.data, encoding: .utf8) == "container1\n" else {
            throw IntegrationError.assert(
                msg: "hostname should default to container id 'container1', got '\(String(data: buffer.data, encoding: .utf8)!)'")
        }
    }

    func testPodStopContainerIdempotency() async throws {
        let id = "test-pod-stop-container-idempotency"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/true"]
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        // Stop container twice - should not fail
        try await pod.stopContainer("container1")
        try await pod.stopContainer("container1")

        try await pod.stop()
    }

    func testPodListContainers() async throws {
        let id = "test-pod-list-containers"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let containerIDs = ["container1", "container2", "container3"]
        for containerID in containerIDs {
            try await pod.addContainer(containerID, rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: containerID)) { config in
                config.process.arguments = ["/bin/true"]
            }
        }

        let listedContainers = await pod.listContainers()

        guard Set(listedContainers) == Set(containerIDs) else {
            throw IntegrationError.assert(
                msg: "listed containers \(listedContainers) != expected \(containerIDs)")
        }

        try await pod.create()
        try await pod.stop()
    }

    func testPodContainerStatistics() async throws {
        let id = "test-pod-container-statistics"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
        }

        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")
            try await pod.startContainer("container2")

            let stats = try await pod.statistics()

            guard stats.count == 2 else {
                throw IntegrationError.assert(msg: "expected 2 container stats, got \(stats.count)")
            }

            let containerIDs = Set(stats.map { $0.id })
            guard containerIDs == Set(["container1", "container2"]) else {
                throw IntegrationError.assert(msg: "unexpected container IDs in stats: \(containerIDs)")
            }

            for stat in stats {
                guard let process = stat.process, process.current > 0 else {
                    throw IntegrationError.assert(msg: "container \(stat.id) process count should be > 0")
                }

                guard let memory = stat.memory, memory.usageBytes > 0 else {
                    throw IntegrationError.assert(msg: "container \(stat.id) memory usage should be > 0")
                }

                print("Container \(stat.id) statistics:")
                print("  Processes: \(process.current)")
                print("  Memory: \(memory.usageBytes) bytes")
                print("  CPU: \(stat.cpu?.usageUsec ?? 0) usec")
            }

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    func testPodMemoryEventsOOMKill() async throws {
        let id = "test-pod-memory-events-oom-kill"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")

            let exec = try await pod.execInContainer("container1", processID: "oom-trigger") { config in
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

            let stats = try await pod.statistics(containerIDs: ["container1"], categories: .memoryEvents)

            guard let containerStats = stats.first, let events = containerStats.memoryEvents else {
                throw IntegrationError.assert(msg: "expected memoryEvents to be present")
            }

            print("Memory events for pod container container1:")
            print("  low: \(events.low)")
            print("  high: \(events.high)")
            print("  max: \(events.max)")
            print("  oom: \(events.oom)")
            print("  oomKill: \(events.oomKill)")

            guard events.oomKill > 0 else {
                throw IntegrationError.assert(msg: "expected oomKill > 0, got \(events.oomKill)")
            }

            try await pod.killContainer("container1", signal: SIGKILL)
            try await pod.waitContainer("container1")
            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    func testPodContainerResourceLimits() async throws {
        let id = "test-pod-container-resource-limits"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
            config.cpus = 2
            config.memoryInBytes = 256.mib()
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")

            // Verify memory limit
            let memoryBuffer = BufferWriter()
            let memoryExec = try await pod.execInContainer("container1", processID: "check-memory") { config in
                config.arguments = ["cat", "/sys/fs/cgroup/memory.max"]
                config.stdout = memoryBuffer
            }
            try await memoryExec.start()
            var status = try await memoryExec.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "check-memory status \(status) != 0")
            }
            try await memoryExec.delete()

            guard let memoryLimit = String(data: memoryBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to parse memory.max")
            }
            let expectedMemory = "\(256.mib())"
            guard memoryLimit == expectedMemory else {
                throw IntegrationError.assert(msg: "memory.max \(memoryLimit) != expected \(expectedMemory)")
            }

            // Verify CPU limit
            let cpuBuffer = BufferWriter()
            let cpuExec = try await pod.execInContainer("container1", processID: "check-cpu") { config in
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

            try await pod.killContainer("container1", signal: SIGKILL)
            try await pod.waitContainer("container1")
            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    func testPodContainerFilesystemIsolation() async throws {
        let id = "test-pod-container-filesystem-isolation"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
        }

        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")
            try await pod.startContainer("container2")

            // Write a file in container1
            let writeExec = try await pod.execInContainer("container1", processID: "write-file") { config in
                config.arguments = ["sh", "-c", "echo 'secret data' > /tmp/container1-secret.txt"]
            }
            try await writeExec.start()
            var status = try await writeExec.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "write-file status \(status) != 0")
            }
            try await writeExec.delete()

            // Verify the file exists in container1
            let readBuffer1 = BufferWriter()
            let readExec1 = try await pod.execInContainer("container1", processID: "read-file-1") { config in
                config.arguments = ["cat", "/tmp/container1-secret.txt"]
                config.stdout = readBuffer1
            }
            try await readExec1.start()
            status = try await readExec1.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "read-file-1 status \(status) != 0")
            }
            try await readExec1.delete()

            guard String(data: readBuffer1.data, encoding: .utf8) == "secret data\n" else {
                throw IntegrationError.assert(msg: "file content in container1 should be 'secret data'")
            }

            // Try to read the file from container2 - should fail
            let readExec2 = try await pod.execInContainer("container2", processID: "read-file-2") { config in
                config.arguments = ["cat", "/tmp/container1-secret.txt"]
            }
            try await readExec2.start()
            status = try await readExec2.wait()
            try await readExec2.delete()

            // File should NOT exist in container2, so cat should fail
            guard status.exitCode != 0 else {
                throw IntegrationError.assert(msg: "file should NOT be accessible from container2")
            }

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    func testPodContainerPIDNamespaceIsolation() async throws {
        let id = "test-pod-container-pid-isolation"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
        }

        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")
            try await pod.startContainer("container2")

            // Start a unique process in container1
            let sleepExec1 = try await pod.execInContainer("container1", processID: "unique-sleep-1") { config in
                config.arguments = ["/bin/sleep", "9999"]
            }
            try await sleepExec1.start()

            // List processes in container1 - should see sleep 9999
            let ps1Buffer = BufferWriter()
            let psExec1 = try await pod.execInContainer("container1", processID: "ps-1") { config in
                config.arguments = ["ps", "aux"]
                config.stdout = ps1Buffer
            }
            try await psExec1.start()
            var status = try await psExec1.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "ps-1 status \(status) != 0")
            }
            try await psExec1.delete()

            guard let ps1Output = String(data: ps1Buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to parse ps output from container1")
            }

            // Verify sleep 9999 is visible in container1
            guard ps1Output.contains("sleep 9999") else {
                throw IntegrationError.assert(msg: "sleep 9999 should be visible in container1")
            }

            // List processes in container2 - should NOT see sleep 9999
            let ps2Buffer = BufferWriter()
            let psExec2 = try await pod.execInContainer("container2", processID: "ps-2") { config in
                config.arguments = ["ps", "aux"]
                config.stdout = ps2Buffer
            }
            try await psExec2.start()
            status = try await psExec2.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "ps-2 status \(status) != 0")
            }
            try await psExec2.delete()

            guard let ps2Output = String(data: ps2Buffer.data, encoding: .utf8) else {
                throw IntegrationError.assert(msg: "failed to parse ps output from container2")
            }

            // Verify sleep 9999 is NOT visible in container2
            guard !ps2Output.contains("sleep 9999") else {
                throw IntegrationError.assert(msg: "sleep 9999 should NOT be visible in container2 (PID namespace isolation failed)")
            }

            try await sleepExec1.delete()
            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    func testPodContainerIndependentResourceLimits() async throws {
        let id = "test-pod-container-independent-limits"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        // Container1 with 1 CPU and 128 MiB memory
        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
            config.cpus = 1
            config.memoryInBytes = 128.mib()
        }

        // Container2 with 2 CPUs and 256 MiB memory
        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
            config.cpus = 2
            config.memoryInBytes = 256.mib()
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")
            try await pod.startContainer("container2")

            // Verify container1 memory limit
            let mem1Buffer = BufferWriter()
            let memExec1 = try await pod.execInContainer("container1", processID: "check-mem-1") { config in
                config.arguments = ["cat", "/sys/fs/cgroup/memory.max"]
                config.stdout = mem1Buffer
            }
            try await memExec1.start()
            var status = try await memExec1.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "check-mem-1 status \(status) != 0")
            }
            try await memExec1.delete()

            guard let mem1Limit = String(data: mem1Buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to parse memory.max from container1")
            }

            let expectedMem1 = "\(128.mib())"
            guard mem1Limit == expectedMem1 else {
                throw IntegrationError.assert(msg: "container1 memory.max \(mem1Limit) != expected \(expectedMem1)")
            }

            // Verify container1 CPU limit
            let cpu1Buffer = BufferWriter()
            let cpuExec1 = try await pod.execInContainer("container1", processID: "check-cpu-1") { config in
                config.arguments = ["cat", "/sys/fs/cgroup/cpu.max"]
                config.stdout = cpu1Buffer
            }
            try await cpuExec1.start()
            status = try await cpuExec1.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "check-cpu-1 status \(status) != 0")
            }
            try await cpuExec1.delete()

            guard let cpu1Limit = String(data: cpu1Buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to parse cpu.max from container1")
            }

            let expectedCpu1 = "100000 100000"  // 1 CPU
            guard cpu1Limit == expectedCpu1 else {
                throw IntegrationError.assert(msg: "container1 cpu.max '\(cpu1Limit)' != expected '\(expectedCpu1)'")
            }

            // Verify container2 memory limit
            let mem2Buffer = BufferWriter()
            let memExec2 = try await pod.execInContainer("container2", processID: "check-mem-2") { config in
                config.arguments = ["cat", "/sys/fs/cgroup/memory.max"]
                config.stdout = mem2Buffer
            }
            try await memExec2.start()
            status = try await memExec2.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "check-mem-2 status \(status) != 0")
            }
            try await memExec2.delete()

            guard let mem2Limit = String(data: mem2Buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to parse memory.max from container2")
            }

            let expectedMem2 = "\(256.mib())"
            guard mem2Limit == expectedMem2 else {
                throw IntegrationError.assert(msg: "container2 memory.max \(mem2Limit) != expected \(expectedMem2)")
            }

            // Verify container2 CPU limit
            let cpu2Buffer = BufferWriter()
            let cpuExec2 = try await pod.execInContainer("container2", processID: "check-cpu-2") { config in
                config.arguments = ["cat", "/sys/fs/cgroup/cpu.max"]
                config.stdout = cpu2Buffer
            }
            try await cpuExec2.start()
            status = try await cpuExec2.wait()
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "check-cpu-2 status \(status) != 0")
            }
            try await cpuExec2.delete()

            guard let cpu2Limit = String(data: cpu2Buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw IntegrationError.assert(msg: "failed to parse cpu.max from container2")
            }

            let expectedCpu2 = "200000 100000"  // 2 CPUs
            guard cpu2Limit == expectedCpu2 else {
                throw IntegrationError.assert(msg: "container2 cpu.max '\(cpu2Limit)' != expected '\(expectedCpu2)'")
            }

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    func testPodSharedPIDNamespace() async throws {
        let id = "test-pod-shared-pid-namespace"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            config.shareProcessNamespace = true
        }

        // First container runs a long-running process
        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/sleep", "300"]
        }

        // Second container checks if it can see container1's sleep process
        let psBuffer = BufferWriter()
        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/sh", "-c", "ps aux | grep 'sleep 300' | grep -v grep"]
            config.process.stdout = psBuffer
        }

        try await pod.create()
        try await pod.startContainer("container1")
        try await Task.sleep(for: .milliseconds(100))

        try await pod.startContainer("container2")
        let status = try await pod.waitContainer("container2")

        try await pod.killContainer("container1", signal: SIGKILL)
        _ = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 should have found the sleep process (status: \(status))")
        }

        let output = String(data: psBuffer.data, encoding: .utf8) ?? ""
        guard output.contains("sleep 300") else {
            throw IntegrationError.assert(msg: "ps output should contain 'sleep 300', got: '\(output)'")
        }
    }

    func testPodReadOnlyRootfs() async throws {
        let id = "test-pod-readonly-rootfs"

        let bs = try await bootstrap(id)
        var rootfs = bs.rootfs
        rootfs.options.append("ro")
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: rootfs) { config in
            config.process.arguments = ["touch", "/testfile"]
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        try await pod.stop()

        // touch should fail on a read-only rootfs
        guard status.exitCode != 0 else {
            throw IntegrationError.assert(msg: "touch should have failed on read-only rootfs")
        }
    }

    func testPodReadOnlyRootfsDNSConfigured() async throws {
        let id = "test-pod-readonly-rootfs-dns"

        let bs = try await bootstrap(id)
        var rootfs = bs.rootfs
        rootfs.options.append("ro")
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: rootfs) { config in
            // Verify /etc/resolv.conf was written before rootfs was remounted read-only
            config.process.arguments = ["cat", "/etc/resolv.conf"]
            config.process.stdout = buffer
            config.dns = DNS(nameservers: ["8.8.8.8", "8.8.4.4"])
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        try await pod.stop()

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

    func testPodSingleFileMount() async throws {
        let id = "test-pod-single-file-mount"

        let bs = try await bootstrap(id)

        // Create a temp file with known content
        let testContent = "Hello from pod single file mount!"
        let hostFile = FileManager.default.uniqueTemporaryDirectory(create: true)
            .appendingPathComponent("pod-config.txt")
        try testContent.write(to: hostFile, atomically: true, encoding: .utf8)

        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["cat", "/etc/myconfig.txt"]
            // Mount a single file using virtiofs share
            config.mounts.append(.share(source: hostFile.path, destination: "/etc/myconfig.txt"))
            config.process.stdout = buffer
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")

            let status = try await pod.waitContainer("container1")
            try await pod.stop()

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
            try? await pod.stop()
            throw error
        }
    }

    func testPodContainerHostsConfig() async throws {
        let id = "test-pod-container-hosts"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["cat", "/etc/hosts"]
            config.process.stdout = buffer
            config.hosts = Hosts(entries: [
                Hosts.Entry.localHostIPV4(),
                Hosts.Entry.localHostIPV6(),
                Hosts.Entry(ipAddress: "10.0.0.50", hostnames: ["myservice.local", "myservice"]),
            ])
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "cat /etc/hosts failed with status \(status)")
        }

        guard let output = String(data: buffer.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert stdout to UTF8")
        }

        guard output.contains("10.0.0.50") && output.contains("myservice.local") else {
            throw IntegrationError.assert(msg: "expected /etc/hosts to contain custom entry, got: \(output)")
        }
    }

    func testPodMultipleContainersDifferentDNS() async throws {
        let id = "test-pod-multi-dns"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["cat", "/etc/resolv.conf"]
            config.process.stdout = buffer1
            config.dns = DNS(nameservers: ["1.1.1.1"])
        }

        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["cat", "/etc/resolv.conf"]
            config.process.stdout = buffer2
            config.dns = DNS(nameservers: ["8.8.8.8"])
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 cat failed with status \(status1)")
        }
        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 cat failed with status \(status2)")
        }

        guard let output1 = String(data: buffer1.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container1 stdout to UTF8")
        }
        guard let output2 = String(data: buffer2.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container2 stdout to UTF8")
        }

        guard output1.contains("1.1.1.1") && !output1.contains("8.8.8.8") else {
            throw IntegrationError.assert(msg: "container1 should have 1.1.1.1 DNS, got: \(output1)")
        }
        guard output2.contains("8.8.8.8") && !output2.contains("1.1.1.1") else {
            throw IntegrationError.assert(msg: "container2 should have 8.8.8.8 DNS, got: \(output2)")
        }
    }

    func testPodMultipleContainersDifferentHosts() async throws {
        let id = "test-pod-multi-hosts"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["cat", "/etc/hosts"]
            config.process.stdout = buffer1
            config.hosts = Hosts(entries: [
                Hosts.Entry.localHostIPV4(),
                Hosts.Entry(ipAddress: "10.0.0.1", hostnames: ["service-a.local", "service-a"]),
            ])
        }

        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["cat", "/etc/hosts"]
            config.process.stdout = buffer2
            config.hosts = Hosts(entries: [
                Hosts.Entry.localHostIPV4(),
                Hosts.Entry(ipAddress: "10.0.0.2", hostnames: ["service-b.local", "service-b"]),
            ])
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 cat failed with status \(status1)")
        }
        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 cat failed with status \(status2)")
        }

        guard let output1 = String(data: buffer1.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container1 stdout to UTF8")
        }
        guard let output2 = String(data: buffer2.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container2 stdout to UTF8")
        }

        guard output1.contains("10.0.0.1") && output1.contains("service-a.local") else {
            throw IntegrationError.assert(msg: "container1 should have service-a entry, got: \(output1)")
        }
        guard !output1.contains("10.0.0.2") && !output1.contains("service-b") else {
            throw IntegrationError.assert(msg: "container1 should NOT have service-b entry, got: \(output1)")
        }

        guard output2.contains("10.0.0.2") && output2.contains("service-b.local") else {
            throw IntegrationError.assert(msg: "container2 should have service-b entry, got: \(output2)")
        }
        guard !output2.contains("10.0.0.1") && !output2.contains("service-a") else {
            throw IntegrationError.assert(msg: "container2 should NOT have service-a entry, got: \(output2)")
        }
    }

    func testPodLevelDNS() async throws {
        let id = "test-pod-level-dns"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            // Set DNS at the pod level
            config.dns = DNS(nameservers: ["9.9.9.9", "149.112.112.112"])
        }

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()

        // Neither container specifies DNS. We should inherit from pod
        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["cat", "/etc/resolv.conf"]
            config.process.stdout = buffer1
        }

        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["cat", "/etc/resolv.conf"]
            config.process.stdout = buffer2
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 cat failed with status \(status1)")
        }
        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 cat failed with status \(status2)")
        }

        guard let output1 = String(data: buffer1.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container1 stdout to UTF8")
        }
        guard let output2 = String(data: buffer2.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container2 stdout to UTF8")
        }

        // Both containers should have the pod-level DNS
        guard output1.contains("9.9.9.9") && output1.contains("149.112.112.112") else {
            throw IntegrationError.assert(msg: "container1 should have pod-level DNS (9.9.9.9), got: \(output1)")
        }
        guard output2.contains("9.9.9.9") && output2.contains("149.112.112.112") else {
            throw IntegrationError.assert(msg: "container2 should have pod-level DNS (9.9.9.9), got: \(output2)")
        }
    }

    func testPodLevelDNSWithContainerOverride() async throws {
        let id = "test-pod-level-dns-override"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            // Set DNS at the pod level
            config.dns = DNS(nameservers: ["9.9.9.9"])
        }

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()

        // Container1 does NOT specify DNS. It should inherit from pod
        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["cat", "/etc/resolv.conf"]
            config.process.stdout = buffer1
        }

        // Container2 specifies its own DNS. It should override pod-level
        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["cat", "/etc/resolv.conf"]
            config.process.stdout = buffer2
            config.dns = DNS(nameservers: ["8.8.8.8"])
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 cat failed with status \(status1)")
        }
        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 cat failed with status \(status2)")
        }

        guard let output1 = String(data: buffer1.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container1 stdout to UTF8")
        }
        guard let output2 = String(data: buffer2.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container2 stdout to UTF8")
        }

        // Container1 should have pod-level DNS
        guard output1.contains("9.9.9.9") && !output1.contains("8.8.8.8") else {
            throw IntegrationError.assert(msg: "container1 should have pod-level DNS (9.9.9.9), got: \(output1)")
        }
        // Container2 should have its own DNS, not pod-level
        guard output2.contains("8.8.8.8") && !output2.contains("9.9.9.9") else {
            throw IntegrationError.assert(msg: "container2 should have container-level DNS (8.8.8.8), got: \(output2)")
        }
    }

    func testPodLevelHosts() async throws {
        let id = "test-pod-level-hosts"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            // Set hosts at the pod level
            config.hosts = Hosts(entries: [
                Hosts.Entry.localHostIPV4(),
                Hosts.Entry(ipAddress: "10.0.0.100", hostnames: ["shared-service.local"]),
            ])
        }

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()

        // Neither container specifies hosts. It should inherit from pod
        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["cat", "/etc/hosts"]
            config.process.stdout = buffer1
        }

        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["cat", "/etc/hosts"]
            config.process.stdout = buffer2
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 cat failed with status \(status1)")
        }
        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 cat failed with status \(status2)")
        }

        guard let output1 = String(data: buffer1.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container1 stdout to UTF8")
        }
        guard let output2 = String(data: buffer2.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container2 stdout to UTF8")
        }

        // Both containers should have the pod-level hosts entry
        guard output1.contains("10.0.0.100") && output1.contains("shared-service.local") else {
            throw IntegrationError.assert(msg: "container1 should have pod-level hosts entry, got: \(output1)")
        }
        guard output2.contains("10.0.0.100") && output2.contains("shared-service.local") else {
            throw IntegrationError.assert(msg: "container2 should have pod-level hosts entry, got: \(output2)")
        }
    }

    func testPodLevelHostsWithContainerOverride() async throws {
        let id = "test-pod-level-hosts-override"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            // Set hosts at the pod level
            config.hosts = Hosts(entries: [
                Hosts.Entry.localHostIPV4(),
                Hosts.Entry(ipAddress: "10.0.0.100", hostnames: ["shared-service.local"]),
            ])
        }

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()

        // Container1 does NOT specify hosts. It should inherit from pod
        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["cat", "/etc/hosts"]
            config.process.stdout = buffer1
        }

        // Container2 specifies its own hosts. It should override pod-level
        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["cat", "/etc/hosts"]
            config.process.stdout = buffer2
            config.hosts = Hosts(entries: [
                Hosts.Entry.localHostIPV4(),
                Hosts.Entry(ipAddress: "10.0.0.200", hostnames: ["container-specific.local"]),
            ])
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 cat failed with status \(status1)")
        }
        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 cat failed with status \(status2)")
        }

        guard let output1 = String(data: buffer1.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container1 stdout to UTF8")
        }
        guard let output2 = String(data: buffer2.data, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to convert container2 stdout to UTF8")
        }

        // Container1 should have pod-level hosts entry
        guard output1.contains("10.0.0.100") && output1.contains("shared-service.local") else {
            throw IntegrationError.assert(msg: "container1 should have pod-level hosts entry, got: \(output1)")
        }
        guard !output1.contains("10.0.0.200") && !output1.contains("container-specific.local") else {
            throw IntegrationError.assert(msg: "container1 should NOT have container2's hosts entry, got: \(output1)")
        }

        // Container2 should have its own hosts entry, not pod-level
        guard output2.contains("10.0.0.200") && output2.contains("container-specific.local") else {
            throw IntegrationError.assert(msg: "container2 should have container-level hosts entry, got: \(output2)")
        }
        guard !output2.contains("10.0.0.100") && !output2.contains("shared-service.local") else {
            throw IntegrationError.assert(msg: "container2 should NOT have pod-level hosts entry, got: \(output2)")
        }
    }

    func testPodLevelHostname() async throws {
        let id = "test-pod-level-hostname"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            // Set hostname at the pod level
            config.hostname = "pod-host"
        }

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()

        // Neither container specifies a hostname. Both should inherit from pod.
        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/hostname"]
            config.process.stdout = buffer1
        }

        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/hostname"]
            config.process.stdout = buffer2
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 hostname failed with status \(status1)")
        }
        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 hostname failed with status \(status2)")
        }

        guard String(data: buffer1.data, encoding: .utf8) == "pod-host\n" else {
            throw IntegrationError.assert(msg: "container1 should have pod-level hostname 'pod-host', got: '\(String(data: buffer1.data, encoding: .utf8) ?? "nil")'")
        }
        guard String(data: buffer2.data, encoding: .utf8) == "pod-host\n" else {
            throw IntegrationError.assert(msg: "container2 should have pod-level hostname 'pod-host', got: '\(String(data: buffer2.data, encoding: .utf8) ?? "nil")'")
        }
    }

    func testPodLevelHostnameWithContainerOverride() async throws {
        let id = "test-pod-level-hostname-override"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            // Set hostname at the pod level
            config.hostname = "pod-host"
        }

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()

        // Container1 does NOT specify a hostname. It should inherit from pod.
        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/hostname"]
            config.process.stdout = buffer1
        }

        // Container2 specifies its own hostname. It should override the pod-level value.
        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/hostname"]
            config.process.stdout = buffer2
            config.hostname = "container-host"
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 hostname failed with status \(status1)")
        }
        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 hostname failed with status \(status2)")
        }

        // Container1 should have the pod-level hostname
        guard String(data: buffer1.data, encoding: .utf8) == "pod-host\n" else {
            throw IntegrationError.assert(msg: "container1 should have pod-level hostname 'pod-host', got: '\(String(data: buffer1.data, encoding: .utf8) ?? "nil")'")
        }
        // Container2 should have its own hostname, not the pod-level one
        guard String(data: buffer2.data, encoding: .utf8) == "container-host\n" else {
            throw IntegrationError.assert(msg: "container2 should have container-level hostname 'container-host', got: '\(String(data: buffer2.data, encoding: .utf8) ?? "nil")'")
        }
    }

    func testPodRLimitOpenFiles() async throws {
        let id = "test-pod-rlimit-open-files"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["sh", "-c", "ulimit -n"]
            config.process.rlimits = [
                LinuxRLimit(kind: .openFiles, hard: 2048, soft: 1024)
            ]
            config.process.stdout = buffer
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        try await pod.stop()

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

    func testPodRLimitExec() async throws {
        let id = "test-pod-rlimit-exec"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["sleep", "100"]
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")

            // Exec a process with rlimits set
            let buffer = BufferWriter()
            let exec = try await pod.execInContainer("container1", processID: "rlimit-exec") { config in
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

            try await pod.killContainer("container1", signal: SIGKILL)
            try await pod.waitContainer("container1")
            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    func testPodUseInitBasic() async throws {
        let id = "test-pod-use-init-basic"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/echo", "hello from pod init"]
            config.process.stdout = buffer
            config.useInit = true
        }

        try await pod.create()
        try await pod.startContainer("container1")

        let status = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }

        guard String(data: buffer.data, encoding: .utf8) == "hello from pod init\n" else {
            throw IntegrationError.assert(
                msg: "expected 'hello from pod init', got '\(String(data: buffer.data, encoding: .utf8) ?? "nil")'")
        }
    }

    func testPodUseInitExitCodePropagation() async throws {
        let id = "test-pod-use-init-exit-code"

        let bs = try await bootstrap(id)

        // Test exit code 0
        var pod = try LinuxPod("\(id)-success", vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "success")) { config in
            config.process.arguments = ["/bin/true"]
            config.useInit = true
        }

        try await pod.create()
        try await pod.startContainer("container1")
        var status = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "expected exit code 0, got \(status.exitCode)")
        }

        // Test non-zero exit code
        pod = try LinuxPod("\(id)-failure", vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "failure")) { config in
            config.process.arguments = ["/bin/false"]
            config.useInit = true
        }

        try await pod.create()
        try await pod.startContainer("container1")
        status = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 1 else {
            throw IntegrationError.assert(msg: "expected exit code 1, got \(status.exitCode)")
        }

        // Test custom exit code
        pod = try LinuxPod("\(id)-custom", vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "custom")) { config in
            config.process.arguments = ["sh", "-c", "exit 42"]
            config.useInit = true
        }

        try await pod.create()
        try await pod.startContainer("container1")
        status = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 42 else {
            throw IntegrationError.assert(msg: "expected exit code 42, got \(status.exitCode)")
        }
    }

    func testPodUseInitSignalForwarding() async throws {
        let id = "test-pod-use-init-signal"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["sleep", "300"]
            config.useInit = true
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")

            try await Task.sleep(for: .milliseconds(100))

            // Send SIGTERM, should be forwarded to the child and cause exit
            try await pod.killContainer("container1", signal: SIGTERM)

            let status = try await pod.waitContainer("container1", timeoutInSeconds: 5)
            try await pod.stop()

            // SIGTERM should result in exit code 128 + 15 = 143
            guard status.exitCode == 143 else {
                throw IntegrationError.assert(msg: "expected exit code 143 (SIGTERM), got \(status.exitCode)")
            }
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    func testPodUseInitMultipleContainers() async throws {
        let id = "test-pod-use-init-multiple"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
        }

        let buffer1 = BufferWriter()
        let buffer2 = BufferWriter()

        // Container1 with useInit
        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["/bin/echo", "container1 with init"]
            config.process.stdout = buffer1
            config.useInit = true
        }

        // Container2 without useInit
        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            config.process.arguments = ["/bin/echo", "container2 without init"]
            config.process.stdout = buffer2
            config.useInit = false
        }

        try await pod.create()

        try await pod.startContainer("container1")
        let status1 = try await pod.waitContainer("container1")

        try await pod.startContainer("container2")
        let status2 = try await pod.waitContainer("container2")

        try await pod.stop()

        guard status1.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container1 exit code \(status1.exitCode) != 0")
        }

        guard status2.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 exit code \(status2.exitCode) != 0")
        }

        guard String(data: buffer1.data, encoding: .utf8) == "container1 with init\n" else {
            throw IntegrationError.assert(
                msg: "container1 output mismatch: '\(String(data: buffer1.data, encoding: .utf8) ?? "nil")'")
        }

        guard String(data: buffer2.data, encoding: .utf8) == "container2 without init\n" else {
            throw IntegrationError.assert(
                msg: "container2 output mismatch: '\(String(data: buffer2.data, encoding: .utf8) ?? "nil")'")
        }
    }

    func testPodUseInitWithSharedPIDNamespace() async throws {
        let id = "test-pod-use-init-shared-pid"

        let bs = try await bootstrap(id)
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            config.shareProcessNamespace = true
        }

        try await pod.addContainer("container1", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container1")) { config in
            config.process.arguments = ["sleep", "300"]
            config.useInit = true
        }

        let psBuffer = BufferWriter()
        try await pod.addContainer("container2", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "container2")) { config in
            // Check if we can see container1's sleep process through the shared PID namespace
            config.process.arguments = ["sh", "-c", "ps aux | grep 'sleep 300' | grep -v grep"]
            config.process.stdout = psBuffer
        }

        try await pod.create()
        try await pod.startContainer("container1")
        try await Task.sleep(for: .milliseconds(100))

        try await pod.startContainer("container2")
        let status = try await pod.waitContainer("container2")

        try await pod.killContainer("container1", signal: SIGKILL)
        _ = try await pod.waitContainer("container1")
        try await pod.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container2 should have found the sleep process (status: \(status))")
        }

        let output = String(data: psBuffer.data, encoding: .utf8) ?? ""
        guard output.contains("sleep 300") else {
            throw IntegrationError.assert(msg: "ps output should contain 'sleep 300', got: '\(output)'")
        }
    }
}
