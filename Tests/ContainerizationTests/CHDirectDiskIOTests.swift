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

#if os(Linux)
import CloudHypervisor
import ContainerizationExtras
import Foundation
import NIO
import NIOHTTP1
import Synchronization
import Testing

@testable import Containerization

/// A virtio-blk disk gets `direct` in the cloud-hypervisor config only when its own
/// mount carries the `directio` runtime option, at boot and on hotplug.
/// The boot tests record the VM config in the `configureCH` of an extension and
/// then fail the start, so cloud-hypervisor never runs.
/// The hotplug tests send `vm.add-disk` to a stub API server on a Unix socket.
struct CHDirectDiskIOTests {
    private struct Captured: Error {}

    private final class CaptureConfig: CHInstanceExtension {
        let config = Mutex<CloudHypervisor.VmConfig?>(nil)

        func configureCH(_ config: inout CloudHypervisor.VmConfig) throws {
            let value = config
            self.config.withLock { $0 = value }
            throw Captured()
        }
    }

    /// Starts a VM with `mounts` as the mounts of container `c1` and returns the
    /// disks of its VM config, the VM rootfs first.
    private func bootDisks(_ mounts: [Mount]) async throws -> [CloudHypervisor.DiskConfig] {
        let runtimeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ch-direct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let capture = CaptureConfig()
        let instance = try CHVirtualMachineInstance(
            runtimeRoot: runtimeRoot,
            chBinary: URL(fileURLWithPath: "/bin/false"),
            virtiofsdBinary: nil
        ) { config in
            config.kernel = Kernel(path: URL(fileURLWithPath: "/dev/null"), platform: .linuxArm)
            config.initialFilesystem = .block(format: "ext4", source: "/tmp/rootfs.ext4", destination: "/")
            config.mountsByID = ["c1": mounts]
            config.extensions = [capture]
        }
        do {
            try await instance.start()
        } catch is Captured {
            return try #require(capture.config.withLock { $0 }?.disks)
        }
        Issue.record("start did not reach configureCH")
        return []
    }

    /// Returns the JSON object that is sent to cloud-hypervisor for `disk`.
    private func encoded(_ disk: CloudHypervisor.DiskConfig) throws -> [String: Any] {
        try jsonObject(JSONEncoder().encode(disk))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func rootfsWithoutFlagHasNoDirect() async throws {
        let containerRootfs = Mount.block(format: "ext4", source: "/tmp/c1.ext4", destination: "/", options: ["ro"])
        let disks = try await bootDisks([containerRootfs])
        #expect(disks.count == 2)
        for disk in disks {
            #expect(disk.direct == nil)
            #expect(try encoded(disk)["direct"] == nil)
        }
    }

    @Test func volumeWithFlagGetsDirect() async throws {
        let volume = Mount.block(
            format: "ext4",
            source: "/tmp/vol.ext4",
            destination: "/data",
            runtimeOptions: ["directio"]
        )
        let disks = try await bootDisks([volume])
        #expect(disks.count == 2)
        #expect(disks[1].path == "/tmp/vol.ext4")
        #expect(disks[1].readonly == false)
        #expect(disks[1].direct == true)
        #expect(try encoded(disks[1])["direct"] as? Bool == true)
    }

    /// The container rootfs is shared by many VMs and stays cached, and the
    /// read-write volume of this VM uses O_DIRECT.
    @Test func sharedRootfsAndDirectVolumeInOneVM() async throws {
        let containerRootfs = Mount.block(format: "ext4", source: "/tmp/shared.ext4", destination: "/", options: ["ro"])
        let volume = Mount.block(
            format: "ext4",
            source: "/tmp/vol.ext4",
            destination: "/data",
            runtimeOptions: ["directio"]
        )
        let disks = try await bootDisks([containerRootfs, volume])
        #expect(disks.map(\.path) == ["/tmp/rootfs.ext4", "/tmp/shared.ext4", "/tmp/vol.ext4"])
        #expect(disks.map(\.direct) == [nil, nil, true])
    }

    /// The flag takes no value, so a `directio=<value>` option is not the flag and
    /// does not start the VM with `direct` set.
    @Test func valueFormsAreNotTheFlag() async throws {
        let withTrue = Mount.block(
            format: "ext4",
            source: "/tmp/true.ext4",
            destination: "/true",
            runtimeOptions: ["directio=true"]
        )
        let withFalse = Mount.block(
            format: "ext4",
            source: "/tmp/false.ext4",
            destination: "/false",
            runtimeOptions: ["directio=false"]
        )
        let disks = try await bootDisks([withTrue, withFalse])
        #expect(disks.map(\.direct) == [nil, nil, nil])
        for disk in disks {
            #expect(try encoded(disk)["direct"] == nil)
        }
    }

    @Test func virtualizationKeysAreIgnored() async throws {
        let vzOnly = Mount.block(
            format: "ext4",
            source: "/tmp/vz.ext4",
            destination: "/vz",
            runtimeOptions: ["vzDiskImageCachingMode=uncached", "vzDiskImageSynchronizationMode=none"]
        )
        let both = Mount.block(
            format: "ext4",
            source: "/tmp/both.ext4",
            destination: "/both",
            runtimeOptions: ["vzDiskImageCachingMode=cached", "directio", "vzTimeout=5"]
        )
        let disks = try await bootDisks([vzOnly, both])
        #expect(disks.map(\.direct) == [nil, nil, true])
    }

    // MARK: - Hotplug

    fileprivate final class Bodies: Sendable {
        let value = Mutex<[Data]>([])
    }

    /// Hotplugs `mount` for container `c1` through a stub cloud-hypervisor API
    /// server, and returns the result and the request bodies that the server got.
    private func hotplug(_ mount: Mount) async throws -> (result: Result<AttachedFilesystem, any Error>, bodies: [Data]) {
        let group = MultiThreadedEventLoopGroup.singleton
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ch-direct-\(UUID().uuidString.prefix(8)).sock").path
        let bodies = Bodies()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
                    try channel.pipeline.syncOperations.addHandler(AddDiskHandler(bodies: bodies))
                }
            }
            .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true)
            .get()

        let client = try CloudHypervisor.Client(socketPath: URL(fileURLWithPath: socketPath), eventLoopGroup: group)
        let provider = CHHotplugProvider(
            client: client,
            workDir: FileManager.default.temporaryDirectory,
            virtiofsdBinary: nil,
            allocator: Character.blockDeviceTagAllocator(),
            initialMounts: [:],
            logger: nil
        )
        let result: Result<AttachedFilesystem, any Error>
        do {
            result = .success(try await provider.hotplug(mount, id: "c1"))
        } catch {
            result = .failure(error)
        }

        try await client.shutdown()
        try await server.close()
        try? FileManager.default.removeItem(atPath: socketPath)
        return (result, bodies.value.withLock { $0 })
    }

    @Test func hotplugHonorsTheFlag() async throws {
        let volume = Mount.block(
            format: "ext4",
            source: "/tmp/vol.ext4",
            destination: "/data",
            runtimeOptions: ["directio"]
        )
        let (result, bodies) = try await hotplug(volume)
        #expect(try result.get().source == "/dev/vda")
        #expect(bodies.count == 1)
        let disk = try JSONDecoder().decode(CloudHypervisor.DiskConfig.self, from: try #require(bodies.first))
        #expect(disk.path == "/tmp/vol.ext4")
        #expect(disk.id == "blk-c1-a")
        #expect(disk.imageType == .raw)
        #expect(disk.direct == true)
    }

    @Test func hotplugWithoutFlagSendsNoDirect() async throws {
        let rootfs = Mount.block(format: "ext4", source: "/tmp/c1.ext4", destination: "/", options: ["ro"])
        let (result, bodies) = try await hotplug(rootfs)
        _ = try result.get()
        #expect(bodies.count == 1)
        let object = try jsonObject(try #require(bodies.first))
        #expect(object["direct"] == nil)
        #expect(object["readonly"] as? Bool == true)
    }

    @Test func hotplugIgnoresValueForms() async throws {
        let volume = Mount.block(
            format: "ext4",
            source: "/tmp/vol.ext4",
            destination: "/data",
            runtimeOptions: ["directio=true"]
        )
        let (result, bodies) = try await hotplug(volume)
        _ = try result.get()
        #expect(bodies.count == 1)
        let object = try jsonObject(try #require(bodies.first))
        #expect(object["direct"] == nil)
    }
}

/// Records each request body and answers with the `PciDeviceInfo` of an added disk.
private final class AddDiskHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let bodies: CHDirectDiskIOTests.Bodies
    private var body: [UInt8] = []

    init(bodies: CHDirectDiskIOTests.Bodies) {
        self.bodies = bodies
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head:
            body = []
        case .body(var buffer):
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            let request = Data(body)
            bodies.value.withLock { $0.append(request) }
            let response = Array(#"{"id":"_disk0","bdf":"0000:00:05.0"}"#.utf8)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: "\(response.count)")
            headers.add(name: "Connection", value: "close")
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: response)))), promise: nil)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                bound.value.close(promise: nil)
            }
        }
    }
}
#endif
