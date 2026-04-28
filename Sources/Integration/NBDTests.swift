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
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import SystemPackage

extension IntegrationSuite {
    private func cloneRootfsForNBD(_ rootfs: Containerization.Mount, testID: String, containerID: String) throws -> Containerization.Mount {
        let clonePath = Self.testDir.appending(component: "\(testID)-\(containerID).ext4").absolutePath()
        try? FileManager.default.removeItem(atPath: clonePath)
        return try rootfs.clone(to: clonePath)
    }

    private func createEXT4DiskImage(testID: String, name: String, size: UInt64 = 64.mib()) throws -> URL {
        let diskURL = Self.testDir.appending(component: "\(testID)-\(name).ext4")
        try? FileManager.default.removeItem(at: diskURL)
        let formatter = try EXT4.Formatter(FilePath(diskURL.absolutePath()), minDiskSize: size)
        try formatter.close()
        return diskURL
    }

    /// Create an ext4 disk image with a file already written to it.
    private func createEXT4DiskImageWithFile(
        testID: String, name: String, filePath: String, content: String, size: UInt64 = 64.mib()
    ) throws -> URL {
        let diskURL = Self.testDir.appending(component: "\(testID)-\(name).ext4")
        try? FileManager.default.removeItem(at: diskURL)
        let formatter = try EXT4.Formatter(FilePath(diskURL.absolutePath()), minDiskSize: size)
        let data = Data(content.utf8)
        let stream = InputStream(data: data)
        stream.open()
        defer { stream.close() }
        try formatter.create(path: FilePath(filePath), mode: 0o100644, buf: stream)
        try formatter.close()
        return diskURL
    }

    private func createNBDServer(testID: String, name: String, size: UInt64 = 64.mib()) throws -> (NBDServer, URL) {
        let diskURL = try createEXT4DiskImage(testID: testID, name: name, size: size)
        let shortID = String(testID.hashValue, radix: 36, uppercase: false)
        let socketPath = "/tmp/nbd-\(shortID)-\(name).sock"
        let server = try NBDServer(filePath: diskURL.path, socketPath: socketPath)
        return (server, diskURL)
    }

    private func readFileFromDiskImage(_ diskURL: URL, path: String) throws -> String {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(diskURL.path))
        let bytes = try reader.readFile(at: FilePath(path))
        guard let content = String(bytes: bytes, encoding: .utf8) else {
            throw IntegrationError.assert(msg: "failed to decode file content from disk image at \(path)")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertVirtioBlockMount(_ output: String, path: String) throws {
        guard output.contains("/dev/vd") else {
            throw IntegrationError.assert(msg: "expected virtio block device (/dev/vd*) for \(path), got: \(output)")
        }
    }

    func testContainerNBDMount() async throws {
        let id = "test-container-nbd-mount"
        let bs = try await bootstrap(id)

        let (server, diskURL) = try createNBDServer(testID: id, name: "vol")
        defer { server.stop() }

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.mounts.append(
                Mount.block(
                    format: "ext4",
                    source: server.url,
                    destination: "/data"
                ))
            config.process.arguments = [
                "/bin/sh", "-c",
                "echo hello > /data/test.txt && cat /data/test.txt && grep /data /proc/mounts",
            ]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container exited with status \(status)")
        }

        let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lines = output.components(separatedBy: "\n")

        guard lines.count >= 2 else {
            throw IntegrationError.assert(msg: "expected at least 2 lines of output, got: \(output)")
        }

        guard lines[0] == "hello" else {
            throw IntegrationError.assert(msg: "expected 'hello', got '\(lines[0])'")
        }

        try assertVirtioBlockMount(lines[1], path: "/data")

        // Verify the write landed on the NBD backing file.
        let diskContent = try readFileFromDiskImage(diskURL, path: "/test.txt")
        guard diskContent == "hello" else {
            throw IntegrationError.assert(msg: "NBD backing file: expected 'hello', got '\(diskContent)'")
        }
    }

    func testContainerNBDReadOnly() async throws {
        let id = "test-container-nbd-readonly"
        let bs = try await bootstrap(id)

        let (server, _) = try createNBDServer(testID: id, name: "ro-vol")
        defer { server.stop() }

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.mounts.append(
                Mount.block(
                    format: "ext4",
                    source: server.url,
                    destination: "/data",
                    options: ["ro"]
                ))
            // Verify virtio block mount, then attempt a write that should fail.
            config.process.arguments = [
                "/bin/sh", "-c",
                "grep /data /proc/mounts; echo test > /data/fail.txt 2>&1; echo exit=$?",
            ]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()

        _ = try await container.wait()
        try await container.stop()

        let output = String(data: buffer.data, encoding: .utf8) ?? ""
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")

        guard !lines.isEmpty else {
            throw IntegrationError.assert(msg: "expected output, got nothing")
        }

        // First line should show the virtio block device mount.
        try assertVirtioBlockMount(lines[0], path: "/data")

        // Write should have failed on a read-only mount.
        guard !output.contains("exit=0") else {
            throw IntegrationError.assert(msg: "write succeeded on read-only NBD mount: \(output)")
        }
    }

    func testContainerNBDVolumeIdentity() async throws {
        let id = "test-container-nbd-volume-identity"
        let bs = try await bootstrap(id)

        let volumeCount = 5
        var servers: [NBDServer] = []

        // Create 5 disk images, each pre-filled with unique content.
        for i in 0..<volumeCount {
            let diskURL = try createEXT4DiskImageWithFile(
                testID: id, name: "vol\(i)", filePath: "/id.txt", content: "container-id-\(i)\n")
            let shortID = String(id.hashValue, radix: 36, uppercase: false)
            let socketPath = "/tmp/nbd-\(shortID)-vol\(i).sock"
            let server = try NBDServer(filePath: diskURL.path, socketPath: socketPath)
            servers.append(server)
        }
        defer {
            for server in servers {
                server.stop()
            }
        }

        // Attach all 5 NBD volumes to a single container and verify each is correct.
        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            for i in 0..<volumeCount {
                config.mounts.append(
                    Mount.block(format: "ext4", source: servers[i].url, destination: "/mnt\(i)"))
            }
            let readCommands = (0..<volumeCount).map { "cat /mnt\($0)/id.txt" }.joined(separator: " && ")
            config.process.arguments = ["/bin/sh", "-c", readCommands]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }

        try await container.create()
        try await container.start()
        let status = try await container.wait()
        try await container.stop()

        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "reader container exited with status \(status)")
        }

        let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lines = output.components(separatedBy: "\n")

        guard lines.count == volumeCount else {
            throw IntegrationError.assert(msg: "expected \(volumeCount) lines, got \(lines.count): \(output)")
        }

        for i in 0..<volumeCount {
            let expected = "container-id-\(i)"
            guard lines[i] == expected else {
                throw IntegrationError.assert(msg: "volume \(i): expected '\(expected)', got '\(lines[i])'")
            }
        }
    }

    func testPodSharedNBDVolume() async throws {
        let id = "test-pod-shared-nbd-volume"
        let bs = try await bootstrap(id)

        let (server, diskURL) = try createNBDServer(testID: id, name: "shared")
        defer { server.stop() }

        let rootfs1 = try cloneRootfsForNBD(bs.rootfs, testID: id, containerID: "writer")
        let rootfs2 = try cloneRootfsForNBD(bs.rootfs, testID: id, containerID: "reader")

        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            config.volumes = [
                .init(
                    name: "shared-data",
                    source: .nbd(url: URL(string: server.url)!),
                    format: "ext4"
                )
            ]
        }

        // Container 1: writes to the shared volume and verifies mount type.
        let writerBuffer = BufferWriter()
        try await pod.addContainer("writer", rootfs: rootfs1) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                "echo shared-content > /data/shared.txt && grep /data /proc/mounts",
            ]
            config.process.stdout = writerBuffer
            config.mounts.append(.sharedMount(name: "shared-data", destination: "/data"))
        }

        // Container 2: reads from the same shared volume at a different path and verifies mount type.
        let readerBuffer = BufferWriter()
        try await pod.addContainer("reader", rootfs: rootfs2) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                "sleep 2 && cat /shared/shared.txt && grep /shared /proc/mounts",
            ]
            config.process.stdout = readerBuffer
            config.mounts.append(.sharedMount(name: "shared-data", destination: "/shared"))
        }

        do {
            try await pod.create()
            try await pod.startContainer("writer")
            try await pod.startContainer("reader")

            let writerStatus = try await pod.waitContainer("writer")
            guard writerStatus.exitCode == 0 else {
                throw IntegrationError.assert(msg: "writer exited with status \(writerStatus)")
            }

            let readerStatus = try await pod.waitContainer("reader")
            guard readerStatus.exitCode == 0 else {
                throw IntegrationError.assert(msg: "reader exited with status \(readerStatus)")
            }

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }

        // Verify writer output.
        let writerOutput = String(data: writerBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let writerLines = writerOutput.components(separatedBy: "\n")
        guard !writerLines.isEmpty else {
            throw IntegrationError.assert(msg: "writer produced no output")
        }
        try assertVirtioBlockMount(writerLines.last!, path: "/data")

        // Verify reader output.
        let readerOutput = String(data: readerBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let readerLines = readerOutput.components(separatedBy: "\n")
        guard readerLines.count >= 2 else {
            throw IntegrationError.assert(msg: "expected at least 2 lines from reader, got: \(readerOutput)")
        }
        guard readerLines[0] == "shared-content" else {
            throw IntegrationError.assert(msg: "expected 'shared-content', got '\(readerLines[0])'")
        }
        try assertVirtioBlockMount(readerLines[1], path: "/shared")

        // Verify the write landed on the NBD backing file.
        let diskContent = try readFileFromDiskImage(diskURL, path: "/shared.txt")
        guard diskContent == "shared-content" else {
            throw IntegrationError.assert(msg: "NBD backing file: expected 'shared-content', got '\(diskContent)'")
        }
    }

    func testPodMultipleNBDVolumes() async throws {
        let id = "test-pod-multiple-nbd-volumes"
        let bs = try await bootstrap(id)

        let (server1, diskURL1) = try createNBDServer(testID: id, name: "vol1")
        defer { server1.stop() }

        let (server2, diskURL2) = try createNBDServer(testID: id, name: "vol2")
        defer { server2.stop() }

        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            config.volumes = [
                .init(
                    name: "volume-a",
                    source: .nbd(url: URL(string: server1.url)!),
                    format: "ext4"
                ),
                .init(
                    name: "volume-b",
                    source: .nbd(url: URL(string: server2.url)!),
                    format: "ext4"
                ),
            ]
        }

        let buffer = BufferWriter()
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                """
                echo aaa > /mnt-a/a.txt && echo bbb > /mnt-b/b.txt \
                && cat /mnt-a/a.txt && cat /mnt-b/b.txt \
                && grep /mnt-a /proc/mounts && grep /mnt-b /proc/mounts
                """,
            ]
            config.process.stdout = buffer
            config.mounts.append(.sharedMount(name: "volume-a", destination: "/mnt-a"))
            config.mounts.append(.sharedMount(name: "volume-b", destination: "/mnt-b"))
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")

            let status = try await pod.waitContainer("container1")
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "container exited with status \(status)")
            }

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }

        let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lines = output.components(separatedBy: "\n")

        guard lines.count >= 4 else {
            throw IntegrationError.assert(msg: "expected at least 4 lines, got: \(output)")
        }

        guard lines[0] == "aaa" && lines[1] == "bbb" else {
            throw IntegrationError.assert(msg: "expected 'aaa\\nbbb', got '\(lines[0])\\n\(lines[1])'")
        }

        try assertVirtioBlockMount(lines[2], path: "/mnt-a")
        try assertVirtioBlockMount(lines[3], path: "/mnt-b")

        // Verify each write landed on the correct NBD backing file.
        let diskContent1 = try readFileFromDiskImage(diskURL1, path: "/a.txt")
        guard diskContent1 == "aaa" else {
            throw IntegrationError.assert(msg: "NBD backing file vol1: expected 'aaa', got '\(diskContent1)'")
        }
        let diskContent2 = try readFileFromDiskImage(diskURL2, path: "/b.txt")
        guard diskContent2 == "bbb" else {
            throw IntegrationError.assert(msg: "NBD backing file vol2: expected 'bbb', got '\(diskContent2)'")
        }
    }

    func testPodUnreferencedVolume() async throws {
        let id = "test-pod-unreferenced-volume"
        let bs = try await bootstrap(id)

        let (server, _) = try createNBDServer(testID: id, name: "unused")
        defer { server.stop() }

        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            config.volumes = [
                .init(
                    name: "unused-vol",
                    source: .nbd(url: URL(string: server.url)!),
                    format: "ext4"
                )
            ]
        }

        // Container doesn't reference the volume at all.
        try await pod.addContainer("container1", rootfs: bs.rootfs) { config in
            config.process.arguments = ["/bin/true"]
        }

        do {
            try await pod.create()
            try await pod.startContainer("container1")

            let status = try await pod.waitContainer("container1")
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "container exited with status \(status)")
            }

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }
    }

    func testPodNBDVolumePersistence() async throws {
        let id = "test-pod-nbd-volume-persistence"
        let bs = try await bootstrap(id)

        let (server, _) = try createNBDServer(testID: id, name: "persistent")
        defer { server.stop() }

        let rootfs1 = try cloneRootfsForNBD(bs.rootfs, testID: id, containerID: "writer")
        let rootfs2 = try cloneRootfsForNBD(bs.rootfs, testID: id, containerID: "reader")

        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            config.volumes = [
                .init(
                    name: "persistent-data",
                    source: .nbd(url: URL(string: server.url)!),
                    format: "ext4"
                )
            ]
        }

        // First container: write data to the volume.
        try await pod.addContainer("writer", rootfs: rootfs1) { config in
            config.process.arguments = ["/bin/sh", "-c", "echo persisted > /data/file.txt && sync"]
            config.mounts.append(.sharedMount(name: "persistent-data", destination: "/data"))
        }

        // Second container: will read the data after the first is stopped.
        let readerBuffer = BufferWriter()
        try await pod.addContainer("reader", rootfs: rootfs2) { config in
            config.process.arguments = ["/bin/sh", "-c", "cat /data/file.txt"]
            config.process.stdout = readerBuffer
            config.mounts.append(.sharedMount(name: "persistent-data", destination: "/data"))
        }

        do {
            try await pod.create()

            // Start writer, wait for it to finish, then stop it.
            try await pod.startContainer("writer")
            let writerStatus = try await pod.waitContainer("writer")
            guard writerStatus.exitCode == 0 else {
                throw IntegrationError.assert(msg: "writer exited with status \(writerStatus)")
            }
            try await pod.stopContainer("writer")

            // Start reader after writer is stopped — data should persist on the volume.
            try await pod.startContainer("reader")
            let readerStatus = try await pod.waitContainer("reader")
            guard readerStatus.exitCode == 0 else {
                throw IntegrationError.assert(msg: "reader exited with status \(readerStatus)")
            }

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }

        let output = String(data: readerBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output == "persisted" else {
            throw IntegrationError.assert(msg: "expected 'persisted', got '\(output ?? "<nil>")'")
        }
    }

    func testPodNBDConcurrentWrites() async throws {
        let id = "test-pod-nbd-concurrent-writes"
        let bs = try await bootstrap(id)

        let (server, _) = try createNBDServer(testID: id, name: "shared")
        defer { server.stop() }

        let rootfs1 = try cloneRootfsForNBD(bs.rootfs, testID: id, containerID: "c1")
        let rootfs2 = try cloneRootfsForNBD(bs.rootfs, testID: id, containerID: "c2")

        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            config.volumes = [
                .init(
                    name: "shared-vol",
                    source: .nbd(url: URL(string: server.url)!),
                    format: "ext4"
                )
            ]
        }

        // Both containers write to different files on the same volume concurrently.
        let buffer1 = BufferWriter()
        try await pod.addContainer("c1", rootfs: rootfs1) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                "echo from-c1 > /vol/c1.txt && sync && cat /vol/c1.txt",
            ]
            config.process.stdout = buffer1
            config.mounts.append(.sharedMount(name: "shared-vol", destination: "/vol"))
        }

        let buffer2 = BufferWriter()
        try await pod.addContainer("c2", rootfs: rootfs2) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                "echo from-c2 > /vol/c2.txt && sync && cat /vol/c2.txt",
            ]
            config.process.stdout = buffer2
            config.mounts.append(.sharedMount(name: "shared-vol", destination: "/vol"))
        }

        do {
            try await pod.create()
            try await pod.startContainer("c1")
            try await pod.startContainer("c2")

            let status1 = try await pod.waitContainer("c1")
            guard status1.exitCode == 0 else {
                throw IntegrationError.assert(msg: "c1 exited with status \(status1)")
            }

            let status2 = try await pod.waitContainer("c2")
            guard status2.exitCode == 0 else {
                throw IntegrationError.assert(msg: "c2 exited with status \(status2)")
            }

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }

        let output1 = String(data: buffer1.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output1 == "from-c1" else {
            throw IntegrationError.assert(msg: "c1: expected 'from-c1', got '\(output1 ?? "<nil>")'")
        }

        let output2 = String(data: buffer2.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output2 == "from-c2" else {
            throw IntegrationError.assert(msg: "c2: expected 'from-c2', got '\(output2 ?? "<nil>")'")
        }
    }

    func testPodNBDVolumeIdentity() async throws {
        let id = "test-pod-nbd-volume-identity"
        let bs = try await bootstrap(id)

        // Create 5 disk images, each pre-filled with unique content.
        let volumeCount = 5
        var servers: [NBDServer] = []

        for i in 0..<volumeCount {
            let diskURL = try createEXT4DiskImageWithFile(
                testID: id, name: "vol\(i)", filePath: "/id.txt", content: "identity-\(i)\n")
            let shortID = String(id.hashValue, radix: 36, uppercase: false)
            let socketPath = "/tmp/nbd-\(shortID)-pvol\(i).sock"
            let server = try NBDServer(filePath: diskURL.path, socketPath: socketPath)
            servers.append(server)
        }
        defer {
            for server in servers {
                server.stop()
            }
        }

        // Create a pod with all 5 volumes and verify each is at the right path.
        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 4
            config.memoryInBytes = 1024.mib()
            config.bootLog = bs.bootLog
            config.volumes = (0..<volumeCount).map { i in
                .init(
                    name: "vol-\(i)",
                    source: .nbd(url: URL(string: servers[i].url)!),
                    format: "ext4"
                )
            }
        }

        // Container reads from all 5 volumes and prints their content.
        let buffer = BufferWriter()
        try await pod.addContainer("reader", rootfs: bs.rootfs) { config in
            let readCommands = (0..<volumeCount).map { i in
                "cat /mnt\(i)/id.txt"
            }.joined(separator: " && ")
            config.process.arguments = ["/bin/sh", "-c", readCommands]
            config.process.stdout = buffer
            for i in 0..<volumeCount {
                config.mounts.append(.sharedMount(name: "vol-\(i)", destination: "/mnt\(i)"))
            }
        }

        do {
            try await pod.create()
            try await pod.startContainer("reader")

            let status = try await pod.waitContainer("reader")
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "reader exited with status \(status)")
            }

            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }

        // Verify each volume's content matches its expected identity.
        let output = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lines = output.components(separatedBy: "\n")

        guard lines.count == volumeCount else {
            throw IntegrationError.assert(msg: "expected \(volumeCount) lines, got \(lines.count): \(output)")
        }

        for i in 0..<volumeCount {
            let expected = "identity-\(i)"
            guard lines[i] == expected else {
                throw IntegrationError.assert(msg: "volume \(i): expected '\(expected)', got '\(lines[i])'")
            }
        }
    }
}
