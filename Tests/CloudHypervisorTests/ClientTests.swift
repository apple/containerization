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

import Foundation
import NIOPosix
import Testing

@testable import CloudHypervisor

@Suite("CloudHypervisor.Client")
struct ClientTests {
    private static let group = MultiThreadedEventLoopGroup.singleton

    // MARK: - Init

    @Test("Client init succeeds with file:// URL")
    func initSucceeds() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.ok()
        }
        defer { Task { try? await server.shutdown() } }

        let socketURL = URL(filePath: server.socketPath)
        let _ = try CloudHypervisor.Client(
            socketPath: socketURL,
            eventLoopGroup: Self.group
        )
    }

    // MARK: - Invalid socket path

    @Test("Client init throws .invalidSocketPath for non-file URL")
    func initThrowsForNonFileURL() throws {
        let url = try #require(URL(string: "https://example.com"))
        #expect(throws: CloudHypervisor.Error.self) {
            try CloudHypervisor.Client(socketPath: url, eventLoopGroup: Self.group)
        }
    }

    // MARK: - Non-2xx response

    @Test("Non-2xx response throws .http with correct status")
    func non2xxThrowsHTTPError() async throws {
        let body = Data("not found".utf8)
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.notFound, body: body)
        }
        defer { Task { try? await server.shutdown() } }

        let socketURL = URL(filePath: server.socketPath)
        let client = try CloudHypervisor.Client(socketPath: socketURL, eventLoopGroup: Self.group)

        struct Dummy: Decodable, Sendable {}

        do {
            let _: Dummy = try await client.get("/api/v1/missing")
            Issue.record("Expected .http error but call succeeded")
        } catch let err as CloudHypervisor.Error {
            guard case .http(let status, let respBody) = err else {
                Issue.record("Expected .http, got \(err)")
                return
            }
            #expect(status == .notFound)
            #expect(respBody == body)
        } catch {
            Issue.record("Expected CloudHypervisor.Error but got \(error)")
        }
    }

    // MARK: - vmmPing

    @Test("vmmPing sends GET /api/v1/vmm.ping and decodes VmmPingResponse")
    func vmmPing() async throws {
        let expected = CloudHypervisor.VmmPingResponse(version: "v40.0", pid: 12345)
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            (try? StubResponse.json(expected)) ?? StubResponse.ok()
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        let result = try await client.vmmPing()

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .GET)
        #expect(recorded[0].uri == "/api/v1/vmm.ping")
        #expect(recorded[0].body.isEmpty)
        #expect(result.version == "v40.0")
        #expect(result.pid == 12345)
    }

    // MARK: - vmmShutdown

    @Test("vmmShutdown sends PUT /api/v1/vmm.shutdown and returns without throwing")
    func vmmShutdown() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        try await client.vmmShutdown()

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vmm.shutdown")
    }

    // MARK: - vmmInfo

    @Test("vmmInfo sends GET /api/v1/vmm.info and decodes VmmInfo")
    func vmmInfo() async throws {
        let expected = CloudHypervisor.VmmInfo(version: "v40.0", pid: 99)
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            (try? StubResponse.json(expected)) ?? StubResponse.ok()
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        let result = try await client.vmmInfo()

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .GET)
        #expect(recorded[0].uri == "/api/v1/vmm.info")
        #expect(result.version == "v40.0")
    }

    // MARK: - vmCreate

    @Test("vmCreate sends PUT /api/v1/vm.create with encoded body")
    func vmCreate() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        let config = CloudHypervisor.VmConfig(
            cpus: .init(bootVcpus: 2, maxVcpus: 4),
            memory: .init(size: 512 * 1024 * 1024),
            payload: .init(kernel: "/boot/vmlinux"),
            console: .init(mode: .Null),
            serial: .init(mode: .Tty)
        )

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        try await client.vmCreate(config)

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.create")

        let decoded = try JSONDecoder().decode(CloudHypervisor.VmConfig.self, from: recorded[0].body)
        #expect(decoded == config)
    }

    // MARK: - vmBoot

    @Test("vmBoot sends PUT /api/v1/vm.boot with no body")
    func vmBoot() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        try await client.vmBoot()

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.boot")
        #expect(recorded[0].body.isEmpty)
    }

    // Regression: cloud-hypervisor's HTTP parser rejects body-less PUTs
    // unless they carry an explicit `Content-Length: 0`. With the
    // AsyncHTTPClient transport, that wire shape is produced by
    // assigning `request.body = .bytes(ByteBuffer())` so AHC's
    // RequestValidation re-derives framing as `known(0)` per RFC 7230
    // §3.3.2. This test asserts the on-the-wire result rather than how
    // it's produced, so any future transport change that drops the
    // empty-body framing surfaces here.
    @Test("Body-less PUT sends Content-Length: 0 with empty body")
    func bodylessPUTSendsContentLengthZero() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(
            socketPath: URL(filePath: server.socketPath),
            eventLoopGroup: Self.group
        )
        try await client.vmBoot()

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        let req = try #require(recorded.first)
        #expect(req.method == .PUT)
        #expect(req.uri == "/api/v1/vm.boot")
        #expect(req.body.isEmpty)
        #expect(req.headers["Content-Length"].first == "0")
    }

    // MARK: - vmShutdown

    @Test("vmShutdown sends PUT /api/v1/vm.shutdown with no body")
    func vmShutdown() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        try await client.vmShutdown()

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.shutdown")
        #expect(recorded[0].body.isEmpty)
    }

    // MARK: - vmInfo

    @Test("vmInfo sends GET /api/v1/vm.info and decodes VmInfo")
    func vmInfo() async throws {
        let expectedConfig = CloudHypervisor.VmConfig(
            cpus: .init(bootVcpus: 1, maxVcpus: 1),
            memory: .init(size: 256 * 1024 * 1024),
            payload: .init(kernel: "/boot/vmlinux"),
            console: .init(mode: .Null),
            serial: .init(mode: .Null)
        )
        let expected = CloudHypervisor.VmInfo(config: expectedConfig, state: .Running)
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            (try? StubResponse.json(expected)) ?? StubResponse.ok()
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        let result = try await client.vmInfo()

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .GET)
        #expect(recorded[0].uri == "/api/v1/vm.info")
        #expect(recorded[0].body.isEmpty)
        #expect(result == expected)
    }

    // MARK: - vmPause

    @Test("vmPause sends PUT /api/v1/vm.pause with no body")
    func vmPause() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        try await client.vmPause()

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.pause")
        #expect(recorded[0].body.isEmpty)
    }

    // MARK: - vmResume

    @Test("vmResume sends PUT /api/v1/vm.resume with no body")
    func vmResume() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        try await client.vmResume()

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.resume")
        #expect(recorded[0].body.isEmpty)
    }

    // MARK: - vmAddDisk

    @Test("vmAddDisk sends PUT /api/v1/vm.add-disk and returns PciDeviceInfo")
    func vmAddDisk() async throws {
        let pciInfo = CloudHypervisor.PciDeviceInfo(id: "_disk0", bdf: "0000:00:01.0")
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            (try? StubResponse.json(pciInfo)) ?? StubResponse.ok()
        }
        defer { Task { try? await server.shutdown() } }

        let config = CloudHypervisor.DiskConfig(path: "/tmp/disk.img", readonly: true, id: "_disk0")
        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        let result = try await client.vmAddDisk(config)

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.add-disk")

        let decoded = try JSONDecoder().decode(CloudHypervisor.DiskConfig.self, from: recorded[0].body)
        #expect(decoded == config)
        #expect(result == pciInfo)
    }

    // MARK: - vmAddFs

    @Test("vmAddFs sends PUT /api/v1/vm.add-fs and returns PciDeviceInfo")
    func vmAddFs() async throws {
        let pciInfo = CloudHypervisor.PciDeviceInfo(id: "_disk0", bdf: "0000:00:01.0")
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            (try? StubResponse.json(pciInfo)) ?? StubResponse.ok()
        }
        defer { Task { try? await server.shutdown() } }

        let config = CloudHypervisor.FsConfig(tag: "myfs", socket: "/tmp/virtiofsd.sock", id: "_fs0")
        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        let result = try await client.vmAddFs(config)

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.add-fs")

        let decoded = try JSONDecoder().decode(CloudHypervisor.FsConfig.self, from: recorded[0].body)
        #expect(decoded == config)
        #expect(result == pciInfo)
    }

    // MARK: - vmAddNet

    @Test("vmAddNet sends PUT /api/v1/vm.add-net and returns PciDeviceInfo")
    func vmAddNet() async throws {
        let pciInfo = CloudHypervisor.PciDeviceInfo(id: "_disk0", bdf: "0000:00:01.0")
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            (try? StubResponse.json(pciInfo)) ?? StubResponse.ok()
        }
        defer { Task { try? await server.shutdown() } }

        let config = CloudHypervisor.NetConfig(tap: "tap0", mac: "AA:BB:CC:DD:EE:FF", id: "_net0")
        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        let result = try await client.vmAddNet(config)

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.add-net")

        let decoded = try JSONDecoder().decode(CloudHypervisor.NetConfig.self, from: recorded[0].body)
        #expect(decoded == config)
        #expect(result == pciInfo)
    }

    // MARK: - vmAddVsock

    @Test("vmAddVsock sends PUT /api/v1/vm.add-vsock and returns PciDeviceInfo")
    func vmAddVsock() async throws {
        let pciInfo = CloudHypervisor.PciDeviceInfo(id: "_disk0", bdf: "0000:00:01.0")
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            (try? StubResponse.json(pciInfo)) ?? StubResponse.ok()
        }
        defer { Task { try? await server.shutdown() } }

        let config = CloudHypervisor.VsockConfig(cid: 3, socket: "/tmp/vsock.sock", id: "_vsock0")
        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        let result = try await client.vmAddVsock(config)

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.add-vsock")

        let decoded = try JSONDecoder().decode(CloudHypervisor.VsockConfig.self, from: recorded[0].body)
        #expect(decoded == config)
        #expect(result == pciInfo)
    }

    // MARK: - vmRemoveDevice

    @Test("vmRemoveDevice sends PUT /api/v1/vm.remove-device with id body")
    func vmRemoveDevice() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        let client = try CloudHypervisor.Client(socketPath: URL(filePath: server.socketPath), eventLoopGroup: Self.group)
        try await client.vmRemoveDevice(id: "_disk0")

        let recorded = server.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].method == .PUT)
        #expect(recorded[0].uri == "/api/v1/vm.remove-device")

        struct RemoveRequest: Decodable { let id: String }
        let decoded = try JSONDecoder().decode(RemoveRequest.self, from: recorded[0].body)
        #expect(decoded.id == "_disk0")
    }

    // MARK: - Malformed JSON

    @Test("Malformed JSON on 200 response throws .decoding")
    func malformedJSONThrowsDecoding() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.ok(Data("not json".utf8))
        }
        defer { Task { try? await server.shutdown() } }

        let socketURL = URL(filePath: server.socketPath)
        let client = try CloudHypervisor.Client(socketPath: socketURL, eventLoopGroup: Self.group)

        struct Dummy: Decodable, Sendable {}

        do {
            let _: Dummy = try await client.get("/api/v1/vmm.info")
            Issue.record("Expected .decoding error but call succeeded")
        } catch let err as CloudHypervisor.Error {
            guard case .decoding = err else {
                Issue.record("Expected .decoding, got \(err)")
                return
            }
            // Expected path — decoding error correctly surfaced.
        } catch {
            Issue.record("Expected CloudHypervisor.Error but got \(error)")
        }
    }

    // MARK: - Shutdown ordering

    /// Regression: with a caller-supplied group, `Client.shutdown()` must
    /// drain the underlying HTTPClient before the caller tears the group
    /// down. Without this, AsyncHTTPClient's deferred connection-cleanup
    /// runs on the (now-dead) event loops and SwiftNIO prints
    /// "Cannot schedule tasks on an EventLoop that has already shut down".
    /// The singleton group used by the rest of this suite can't surface
    /// the bug because it never shuts down, so we spin up a dedicated
    /// group for the client here. The server stays on the singleton so
    /// only the client-side AHC channels are at risk when we shut the
    /// owned group down — otherwise the server's own pipeline cleanup
    /// would race the same group teardown and confound the test.
    @Test("Client.shutdown drains HTTPClient before a caller-owned group is torn down")
    func shutdownDrainsHTTPClientBeforeGroup() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let client = try CloudHypervisor.Client(
            socketPath: URL(filePath: server.socketPath),
            eventLoopGroup: clientGroup
        )
        // Round-trip a real request so AHC actually opens a connection
        // and parks its post-response cleanup on `clientGroup`.
        try await client.vmmShutdown()

        try await client.shutdown()
        // Idempotent — a second call must not throw.
        try await client.shutdown()

        // The owned group should now be safe to tear down without NIO
        // warnings.
        try await clientGroup.shutdownGracefully()
    }

    @Test("Client.shutdown also tears down the group when the client owns it")
    func shutdownOwnsGroup() async throws {
        let server = try await StubHTTPServer(eventLoopGroup: Self.group) { _ in
            StubResponse.status(.noContent)
        }
        defer { Task { try? await server.shutdown() } }

        // No eventLoopGroup → client owns its own.
        let client = try CloudHypervisor.Client(
            socketPath: URL(filePath: server.socketPath)
        )
        try await client.vmmShutdown()
        try await client.shutdown()
        // Idempotent.
        try await client.shutdown()
    }
}
