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
import ContainerizationError
import ContainerizationExtras
import Foundation
import Testing

@testable import Containerization

private struct NilGatewayInterface: Interface {
    let ipv4Address: CIDRv4
    let ipv4Gateway: IPv4Address? = nil
    let macAddress: MACAddress? = nil

    init() {
        self.ipv4Address = try! CIDRv4("192.168.64.2/24")
    }
}

private struct NilGatewayNetwork: ContainerManager.Network {
    mutating func create(_ id: String) throws -> Interface? {
        NilGatewayInterface()
    }

    mutating func release(_ id: String) throws {}
}

@Suite
struct ContainerManagerTests {
    @Test func testCreateThrowsWhenGatewayMissing() async throws {
        let fm = FileManager.default
        let root = fm.uniqueTemporaryDirectory(create: true)
        defer { try? fm.removeItem(at: root) }

        let kernelPath = root.appendingPathComponent("vmlinux")
        fm.createFile(atPath: kernelPath.path, contents: Data(), attributes: nil)
        let initfsPath = root.appendingPathComponent("initfs.ext4")
        fm.createFile(atPath: initfsPath.path, contents: Data(), attributes: nil)

        let kernel = Kernel(path: kernelPath, platform: .linuxArm)
        let initfs = Mount.block(format: "ext4", source: initfsPath.path, destination: "/")

        var manager = try ContainerManager(
            kernel: kernel,
            initfs: initfs,
            root: root,
            network: NilGatewayNetwork()
        )

        let tempDir = fm.uniqueTemporaryDirectory()
        defer { try? fm.removeItem(at: tempDir) }

        let tarPath = Foundation.Bundle.module.url(forResource: "scratch", withExtension: "tar")!
        let reader = try ArchiveReader(format: .pax, filter: .none, file: tarPath)
        let rejectedPaths = try reader.extractContents(to: tempDir)
        #expect(rejectedPaths.isEmpty)

        let images = try await manager.imageStore.load(from: tempDir)
        let image = images.first!

        let rootfsPath = root.appendingPathComponent("rootfs.ext4")
        fm.createFile(atPath: rootfsPath.path, contents: Data(), attributes: nil)
        let rootfs = Mount.block(format: "ext4", source: rootfsPath.path, destination: "/")

        do {
            _ = try await manager.create("test-nil-gateway", image: image, rootfs: rootfs) { _ in }
            #expect(Bool(false), "expected invalidState error for missing ipv4 gateway")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
            #expect(error.message.contains("missing ipv4 gateway"))
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }
    }

    @Test func testNetworkingFalseSkipsInterfaceCreation() async throws {
        let fm = FileManager.default
        let root = fm.uniqueTemporaryDirectory(create: true)
        defer { try? fm.removeItem(at: root) }

        let kernelPath = root.appendingPathComponent("vmlinux")
        fm.createFile(atPath: kernelPath.path, contents: Data(), attributes: nil)
        let initfsPath = root.appendingPathComponent("initfs.ext4")
        fm.createFile(atPath: initfsPath.path, contents: Data(), attributes: nil)

        let kernel = Kernel(path: kernelPath, platform: .linuxArm)
        let initfs = Mount.block(format: "ext4", source: initfsPath.path, destination: "/")

        // Use NilGatewayNetwork — with networking: true this would throw invalidState,
        // but with networking: false the network's create() is never called.
        var manager = try ContainerManager(
            kernel: kernel,
            initfs: initfs,
            root: root,
            network: NilGatewayNetwork()
        )

        let tempDir = fm.uniqueTemporaryDirectory()
        defer { try? fm.removeItem(at: tempDir) }

        let tarPath = Foundation.Bundle.module.url(forResource: "scratch", withExtension: "tar")!
        let reader = try ArchiveReader(format: .pax, filter: .none, file: tarPath)
        let rejectedPaths = try reader.extractContents(to: tempDir)
        #expect(rejectedPaths.isEmpty)

        let images = try await manager.imageStore.load(from: tempDir)
        let image = images.first!

        let rootfsPath = root.appendingPathComponent("rootfs.ext4")
        fm.createFile(atPath: rootfsPath.path, contents: Data(), attributes: nil)
        let rootfs = Mount.block(format: "ext4", source: rootfsPath.path, destination: "/")

        // With networking: false, NilGatewayNetwork.create() is never called,
        // so we should not get the "missing ipv4 gateway" error.
        // The container creation will fail for other reasons (dummy VMM), but the
        // configuration closure should see empty interfaces.
        var closureWasCalled = false
        do {
            _ = try await manager.create(
                "test-no-networking",
                image: image,
                rootfs: rootfs,
                networking: false
            ) { config in
                closureWasCalled = true
                #expect(config.interfaces.isEmpty)
                #expect(config.dns == nil)
            }
        } catch {
            // Container creation may fail due to dummy kernel/VMM — that's expected.
            // The key assertion is in the configuration closure above.
            let description = String(describing: error)
            #expect(!description.contains("missing ipv4 gateway"))
        }
        #expect(closureWasCalled, "configuration closure must be invoked to validate interfaces")
    }
}
