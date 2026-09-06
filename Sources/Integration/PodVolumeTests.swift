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
import ContainerizationOS
import Foundation
import Logging
import SystemPackage

#if os(macOS)
extension IntegrationSuite {
    private func cloneRootfsForContainer(_ rootfs: Containerization.Mount, testID: String, containerID: String) throws -> Containerization.Mount {
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

    func testContainerNBDRawBlock() async throws {
        let id = "test-container-nbd-raw-block"
        let bs = try await bootstrap(id)

        // Create an unformatted disk image, no filesystem.
        let diskURL = Self.testDir.appending(component: "\(id)-raw.img")
        try? FileManager.default.removeItem(at: diskURL)
        FileManager.default.createFile(atPath: diskURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: diskURL)
        try fh.truncate(atOffset: 64.mib())
        try fh.close()

        let shortID = String(id.hashValue, radix: 36, uppercase: false)
        let socketPath = "/tmp/nbd-\(shortID)-raw.sock"
        let server = try NBDServer(filePath: diskURL.path, socketPath: socketPath)
        defer { server.stop() }

        let buffer = BufferWriter()
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            // Attach as raw block, bind mount the device into the container.
            config.mounts.append(
                Mount.block(
                    format: "none",
                    source: server.url,
                    destination: "/dev/my-disk",
                    options: ["bind"]
                ))
            // Verify it's a block device, write known data, read it back.
            config.process.arguments = [
                "/bin/sh", "-c",
                "test -b /dev/my-disk && printf 'raw-block-works' | dd of=/dev/my-disk bs=512 count=1 conv=sync 2>/dev/null && dd if=/dev/my-disk bs=1 count=15 2>/dev/null",
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
        guard output == "raw-block-works" else {
            throw IntegrationError.assert(msg: "expected 'raw-block-works', got '\(output)'")
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

        let rootfs1 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "writer")
        let rootfs2 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "reader")

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

        let rootfs1 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "writer")
        let rootfs2 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "reader")

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

        let rootfs1 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "c1")
        let rootfs2 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "c2")

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

    /// Attach an empty EXT4 disk-image file as a pod volume and have
    /// multiple containers read from and write to the shared mount.
    func testPodSharedDiskImageVolume() async throws {
        let id = "test-pod-shared-disk-image-volume"
        let bs = try await bootstrap(id)

        // Create an empty EXT4 disk image to back the shared volume.
        let diskURL = try createEXT4DiskImage(testID: id, name: "shared")

        let rootfs1 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "writer")
        let rootfs2 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "appender")
        let rootfs3 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "reader")

        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 1
            config.memoryInBytes = 512.mib()
            config.bootLog = bs.bootLog
            config.volumes = [
                .init(
                    name: "shared-data",
                    source: .diskImage(path: diskURL),
                    format: "ext4"
                )
            ]
        }

        // Container 1: writes a file to the shared volume and verifies mount type.
        let writerBuffer = BufferWriter()
        try await pod.addContainer("writer", rootfs: rootfs1) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                "echo shared-content > /data/shared.txt && grep /data /proc/mounts",
            ]
            config.process.stdout = writerBuffer
            config.mounts.append(.sharedMount(name: "shared-data", destination: "/data"))
        }

        // Container 2: reads what the writer produced and writes a second file,
        // mounted at a different path to prove it's the same backing store.
        let appenderBuffer = BufferWriter()
        try await pod.addContainer("appender", rootfs: rootfs2) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                "cat /vol/shared.txt && echo more-content > /vol/second.txt",
            ]
            config.process.stdout = appenderBuffer
            config.mounts.append(.sharedMount(name: "shared-data", destination: "/vol"))
        }

        // Container 3: reads both files written by the previous containers.
        let readerBuffer = BufferWriter()
        try await pod.addContainer("reader", rootfs: rootfs3) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                "cat /shared/shared.txt && cat /shared/second.txt && grep /shared /proc/mounts",
            ]
            config.process.stdout = readerBuffer
            config.mounts.append(.sharedMount(name: "shared-data", destination: "/shared"))
        }

        do {
            try await pod.create()

            // Run the containers sequentially so reads see prior writes.
            try await pod.startContainer("writer")
            let writerStatus = try await pod.waitContainer("writer")
            guard writerStatus.exitCode == 0 else {
                throw IntegrationError.assert(msg: "writer exited with status \(writerStatus)")
            }

            try await pod.startContainer("appender")
            let appenderStatus = try await pod.waitContainer("appender")
            guard appenderStatus.exitCode == 0 else {
                throw IntegrationError.assert(msg: "appender exited with status \(appenderStatus)")
            }

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

        // Verify writer mounted a virtio block device at /data.
        let writerOutput = String(data: writerBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let writerLines = writerOutput.components(separatedBy: "\n")
        guard !writerLines.isEmpty else {
            throw IntegrationError.assert(msg: "writer produced no output")
        }
        try assertVirtioBlockMount(writerLines.last!, path: "/data")

        // Verify the appender read the writer's file.
        let appenderOutput = String(data: appenderBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard appenderOutput == "shared-content" else {
            throw IntegrationError.assert(msg: "appender: expected 'shared-content', got '\(appenderOutput)'")
        }

        // Verify the reader saw both files and a virtio block mount.
        let readerOutput = String(data: readerBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let readerLines = readerOutput.components(separatedBy: "\n")
        guard readerLines.count >= 3 else {
            throw IntegrationError.assert(msg: "expected at least 3 lines from reader, got: \(readerOutput)")
        }
        guard readerLines[0] == "shared-content" else {
            throw IntegrationError.assert(msg: "reader: expected 'shared-content', got '\(readerLines[0])'")
        }
        guard readerLines[1] == "more-content" else {
            throw IntegrationError.assert(msg: "reader: expected 'more-content', got '\(readerLines[1])'")
        }
        try assertVirtioBlockMount(readerLines[2], path: "/shared")

        // Verify both writes landed on the host-side EXT4 disk image.
        let firstContent = try readFileFromDiskImage(diskURL, path: "/shared.txt")
        guard firstContent == "shared-content" else {
            throw IntegrationError.assert(msg: "disk image /shared.txt: expected 'shared-content', got '\(firstContent)'")
        }
        let secondContent = try readFileFromDiskImage(diskURL, path: "/second.txt")
        guard secondContent == "more-content" else {
            throw IntegrationError.assert(msg: "disk image /second.txt: expected 'more-content', got '\(secondContent)'")
        }
    }

    /// Attach an in-memory tmpfs pod volume shared across two containers: one
    /// writes a file and verifies the mount type/size, the other reads the file
    /// back from a different mount path to prove it is the same backing store.
    func testPodSharedTmpfsVolume() async throws {
        let id = "test-pod-shared-tmpfs-volume"
        let bs = try await bootstrap(id)

        let rootfs1 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "writer")
        let rootfs2 = try cloneRootfsForContainer(bs.rootfs, testID: id, containerID: "reader")

        let pod = try LinuxPod(id, vmm: bs.vmm) { config in
            config.cpus = 1
            config.memoryInBytes = 512.mib()
            config.bootLog = bs.bootLog
            config.volumes = [
                .init(
                    name: "mytmpfs",
                    source: .tmpfs(sizeBytes: 128.mib()),
                    format: "tmpfs"
                )
            ]
        }

        // Container 1: writes a file to the shared tmpfs volume and verifies mount type.
        let writerBuffer = BufferWriter()
        try await pod.addContainer("writer", rootfs: rootfs1) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                "echo bar > /my-tmpfs-mount/foo && grep /my-tmpfs-mount /proc/mounts",
            ]
            config.process.stdout = writerBuffer
            config.mounts.append(.sharedMount(name: "mytmpfs", destination: "/my-tmpfs-mount"))
        }

        // Container 2: reads the file the writer produced, mounted at a different
        // path to prove it is the same in-memory backing store.
        let readerBuffer = BufferWriter()
        try await pod.addContainer("reader", rootfs: rootfs2) { config in
            config.process.arguments = [
                "/bin/sh", "-c",
                "cat /shared-tmpfs/foo && grep /shared-tmpfs /proc/mounts",
            ]
            config.process.stdout = readerBuffer
            config.mounts.append(.sharedMount(name: "mytmpfs", destination: "/shared-tmpfs"))
        }

        do {
            try await pod.create()

            // Run sequentially so the reader observes the writer's file.
            try await pod.startContainer("writer")
            let writerStatus = try await pod.waitContainer("writer")
            guard writerStatus.exitCode == 0 else {
                throw IntegrationError.assert(msg: "writer exited with status \(writerStatus)")
            }

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

        // Verify the writer mounted a tmpfs of the expected size.
        let writerOut = String(data: writerBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard writerOut.contains("tmpfs /my-tmpfs-mount tmpfs") else {
            throw IntegrationError.assert(msg: "pod volume /my-tmpfs-mount is not backed by tmpfs: \(writerOut)")
        }
        // tmpfs reports its size in /proc/mounts in kibibytes with a trailing 'k'.
        let expectedSizeKiB: UInt64 = 128 * 1024
        guard writerOut.contains("size=\(expectedSizeKiB)k") else {
            throw IntegrationError.assert(msg: "tmpfs mount is not of expected size (\(expectedSizeKiB)k): \(writerOut)")
        }

        // Verify the reader saw the writer's file on the shared tmpfs at its own path.
        let readerOut = String(data: readerBuffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let readerLines = readerOut.components(separatedBy: "\n")
        guard readerLines.count >= 2 else {
            throw IntegrationError.assert(msg: "expected at least 2 lines from reader, got: \(readerOut)")
        }
        guard readerLines[0] == "bar" else {
            throw IntegrationError.assert(msg: "reader: expected 'bar', got '\(readerLines[0])'")
        }
        guard readerOut.contains("tmpfs /shared-tmpfs tmpfs") else {
            throw IntegrationError.assert(msg: "reader mount /shared-tmpfs is not backed by tmpfs: \(readerOut)")
        }
    }

    /// `cctl run --block` in filesystem mode: the ext4 on the NBD export is
    /// mounted at dst, and a write from the container lands on the backing file.
    func testCctlBlockNBDMount() async throws {
        let id = "test-cctl-block-nbd-mount"
        let (server, diskURL) = try createNBDServer(testID: id, name: "cctl-vol")
        defer { server.stop() }

        let (output, exitCode) = try runCctl(arguments: [
            "run",
            "--kernel", self.kernel,
            "--id", id,
            "--block", "src=\(server.url),dst=/data,fmt=ext4",
            "/bin/sh", "-c",
            "grep /data /proc/mounts; printf 'cctl-block-works' > /data/hello.txt",
        ])

        guard exitCode == 0 else {
            throw IntegrationError.assert(msg: "cctl run exited with \(exitCode): \(output)")
        }

        // The mount must be backed by a virtio block device, not a virtiofs share.
        try assertVirtioBlockMount(output, path: "/data")

        // Read the file back off the NBD backing file to prove the write
        // traversed guest -> virtio-blk -> NBD -> host.
        let content = try readFileFromDiskImage(diskURL, path: "/hello.txt")
        guard content == "cctl-block-works" else {
            throw IntegrationError.assert(msg: "NBD backing file: expected 'cctl-block-works', got '\(content)'")
        }
    }

    /// `cctl run --block ...,raw`: the device node is bind mounted rather than
    /// mounted as a filesystem, so an unformatted export is usable directly.
    func testCctlBlockNBDRaw() async throws {
        let id = "test-cctl-block-nbd-raw"

        // No filesystem — a bare sparse file, to prove `raw` never reads a superblock.
        let diskURL = Self.testDir.appending(component: "\(id)-raw.img")
        try? FileManager.default.removeItem(at: diskURL)
        FileManager.default.createFile(atPath: diskURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: diskURL)
        try fh.truncate(atOffset: 64.mib())
        try fh.close()

        let shortID = String(id.hashValue, radix: 36, uppercase: false)
        let socketPath = "/tmp/nbd-\(shortID)-cctl-raw.sock"
        let server = try NBDServer(filePath: diskURL.path, socketPath: socketPath)
        defer { server.stop() }

        let (output, exitCode) = try runCctl(arguments: [
            "run",
            "--kernel", self.kernel,
            "--id", id,
            "--block", "src=\(server.url),dst=/dev/my-disk,raw",
            "/bin/sh", "-c",
            "test -b /dev/my-disk && printf 'raw-via-cctl' | dd of=/dev/my-disk bs=512 count=1 conv=sync 2>/dev/null && dd if=/dev/my-disk bs=1 count=12 2>/dev/null",
        ])

        guard exitCode == 0 else {
            throw IntegrationError.assert(msg: "cctl run exited with \(exitCode): \(output)")
        }

        guard output.contains("raw-via-cctl") else {
            throw IntegrationError.assert(msg: "expected 'raw-via-cctl' in output, got '\(output)'")
        }
    }

    /// A malformed `--block` value must fail as a usage error before any VM boots.
    func testCctlBlockRejectsInvalidSpec() async throws {
        let (output, exitCode) = try runCctl(arguments: [
            "run",
            "--kernel", self.kernel,
            "--id", "test-cctl-block-invalid",
            "--block", "dst=/data",
            "/bin/true",
        ])

        guard exitCode != 0 else {
            throw IntegrationError.assert(msg: "expected non-zero exit for malformed --block, got 0: \(output)")
        }
        guard output.contains("requires src=") else {
            throw IntegrationError.assert(msg: "expected a src= usage error, got: \(output)")
        }
    }

    /// Format an unformatted NBD export from inside the container, then prove
    /// the filesystem survives the container exiting.
    ///
    /// Two sequential `cctl run` invocations against one long-lived NBD
    /// server, each a separate VM:
    ///   1. assert the export has no filesystem, then `mkfs` it
    ///   2. fresh container — read the same filesystem UUID back
    ///
    /// Uses `raw` mode (a bind mounted device node) rather than a filesystem
    /// mount
    func testCctlBlockNBDFormatAndPersist() async throws {
        let id = "test-cctl-block-nbd-format-persist"

        // A bare sparse file — deliberately NOT formatted by the host, so the
        // filesystem observed in run 2 can only have come from run 1.
        let diskURL = Self.testDir.appending(component: "\(id).img")
        try? FileManager.default.removeItem(at: diskURL)
        FileManager.default.createFile(atPath: diskURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: diskURL)
        try fh.truncate(atOffset: 64.mib())
        try fh.close()

        let shortID = String(id.hashValue, radix: 36, uppercase: false)
        let socketPath = "/tmp/nbd-\(shortID)-persist.sock"
        // One server for all runs: each container reconnects to the same export.
        let server = try NBDServer(filePath: diskURL.path, socketPath: socketPath)
        defer { server.stop() }

        let blockSpec = "src=\(server.url),dst=/dev/vol,raw"

        // Run 1: verify unformatted, then format.
        let (out1, code1) = try runCctl(arguments: [
            "run", "--kernel", self.kernel, "--id", "\(id)-1",
            "--block", blockSpec,
            "/bin/sh", "-c",
            """
            if [ -n "$(blkid /dev/vol 2>/dev/null)" ]; then echo UNEXPECTED_FS; else echo no-fs-yet; fi
            mkfs.vfat /dev/vol >/dev/null 2>&1 && echo mkfs-ok || echo mkfs-failed
            blkid /dev/vol
            """,
        ])

        guard code1 == 0 else {
            throw IntegrationError.assert(msg: "run 1 exited with \(code1): \(out1)")
        }
        // The export must have started with no filesystem, or the test proves nothing.
        // Note: busybox `blkid` exits 0 with empty output on an unformatted
        // device, so the guest script tests output emptiness, not exit status.
        guard out1.contains("no-fs-yet"), !out1.contains("UNEXPECTED_FS") else {
            throw IntegrationError.assert(msg: "run 1: export already had a filesystem: \(out1)")
        }
        guard out1.contains("mkfs-ok") else {
            throw IntegrationError.assert(msg: "run 1: mkfs failed: \(out1)")
        }
        guard let uuid = Self.parseBlkidUUID(out1) else {
            throw IntegrationError.assert(msg: "run 1: no filesystem UUID after mkfs: \(out1)")
        }

        // Run 2: a brand new VM and container against the same export.
        let (out2, code2) = try runCctl(arguments: [
            "run", "--kernel", self.kernel, "--id", "\(id)-2",
            "--block", blockSpec,
            "/bin/sh", "-c",
            "blkid /dev/vol",
        ])

        guard code2 == 0 else {
            throw IntegrationError.assert(msg: "run 2 exited with \(code2): \(out2)")
        }
        // Same UUID => the very filesystem run 1 created, not a coincidental reformat.
        guard let uuid2 = Self.parseBlkidUUID(out2), uuid2 == uuid else {
            throw IntegrationError.assert(msg: "run 2: expected filesystem UUID \(uuid), got: \(out2)")
        }
    }

    /// Extract the `UUID="..."` value from `blkid` output, if present.
    private static func parseBlkidUUID(_ output: String) -> String? {
        guard let range = output.range(of: "UUID=\"") else {
            return nil
        }
        let rest = output[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else {
            return nil
        }
        return String(rest[..<end])
    }
}
#endif
