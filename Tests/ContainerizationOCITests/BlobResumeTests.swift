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

import ContainerizationError
import Crypto
import Foundation
import NIO
import NIOHTTP1
import Synchronization
import Testing

@testable import ContainerizationOCI

/// Returns the start of a `bytes=<start>-` range header.
private func rangeStart(_ header: String?) -> Int? {
    guard let header, header.hasPrefix("bytes="), header.hasSuffix("-") else {
        return nil
    }
    return Int(header.dropFirst("bytes=".count).dropLast())
}

/// Serves a blob on loopback, optionally honoring Range, and drops the connection
/// halfway through the body for the first `drops` requests.
private final class BlobStubServer: Sendable {
    let port: Int
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup
    private let shared: Shared

    struct State {
        var drops: Int
        var rangeHeaders: [String?] = []
    }

    final class Shared: Sendable {
        let state: Mutex<State>

        init(_ state: State) {
            self.state = Mutex(state)
        }
    }

    var rangeHeaders: [String?] {
        shared.state.withLock { $0.rangeHeaders }
    }

    static func start(blob: [UInt8], drops: Int, honorRange: Bool) async throws -> BlobStubServer {
        let shared = Shared(State(drops: drops))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
                    try channel.pipeline.syncOperations.addHandler(Handler(blob: blob, honorRange: honorRange, shared: shared))
                }
            }

        do {
            let bound = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            guard let port = bound.localAddress?.port else {
                try? await bound.close().get()
                throw ContainerizationError(.internalError, message: "stub server bound without a port")
            }
            return BlobStubServer(port: port, channel: bound, group: group, shared: shared)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private init(port: Int, channel: Channel, group: MultiThreadedEventLoopGroup, shared: Shared) {
        self.port = port
        self.channel = channel
        self.group = group
        self.shared = shared
    }

    func shutdown() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let blob: [UInt8]
        private let honorRange: Bool
        private let shared: Shared
        private var range: String?

        init(blob: [UInt8], honorRange: Bool, shared: Shared) {
            self.blob = blob
            self.honorRange = honorRange
            self.shared = shared
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                range = head.headers.first(name: "Range")
                return
            case .body:
                return
            case .end:
                break
            }

            let drop = shared.state.withLock { state in
                state.rangeHeaders.append(range)
                guard state.drops > 0 else {
                    return false
                }
                state.drops -= 1
                return true
            }

            var start = 0
            var status = HTTPResponseStatus.ok
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/octet-stream")
            if honorRange, let offset = rangeStart(range) {
                start = offset
                status = .partialContent
                headers.add(name: "Content-Range", value: "bytes \(offset)-\(blob.count - 1)/\(blob.count)")
            }
            headers.add(name: "Content-Length", value: "\(blob.count - start)")

            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            if drop {
                // Send half of what was promised, then cut the connection.
                let end = start + (blob.count - start) / 2
                let body = context.channel.allocator.buffer(bytes: blob[start..<end])
                let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
                context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(body)))).whenComplete { _ in
                    boundContext.value.close(promise: nil)
                }
                return
            }
            let body = context.channel.allocator.buffer(bytes: blob[start...])
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }
}

/// Drives `fetchBlob(name:descriptor:into:progress:)` against a loopback server
/// that drops the connection mid-body.
@Suite(.enabled(if: reachesLoopbackDirectly))
struct BlobResumeTests {
    // Large enough to span several reads; a non-repeating pattern catches misordered bytes.
    private static let blob: [UInt8] = (0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 * 31) }
    private static let descriptor = Descriptor(
        mediaType: MediaTypes.imageLayerGzip,
        digest: SHA256.hash(data: blob).digestString,
        size: Int64(blob.count)
    )
    private static let retryOptions = RetryOptions(maxRetries: 3, retryInterval: 1_000_000)  // 1ms

    private func fetch(drops: Int, honorRange: Bool) async throws -> (digest: SHA256Digest, data: Data, ranges: [String?]) {
        let server = try await BlobStubServer.start(blob: Self.blob, drops: drops, honorRange: honorRange)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        let client = RegistryClient(host: "127.0.0.1", scheme: "http", port: server.port, retryOptions: Self.retryOptions)
        do {
            let (_, digest) = try await client.fetchBlob(name: "test/image", descriptor: Self.descriptor, into: file, progress: nil)
            let data = try Data(contentsOf: file)
            let ranges = server.rangeHeaders
            try await server.shutdown()
            return (digest, data, ranges)
        } catch {
            try? await server.shutdown()
            throw error
        }
    }

    /// The client may receive fewer bytes than the server sent before the connection
    /// dropped, so only check that it resumed from somewhere inside the blob.
    private func isResume(_ header: String?) -> Bool {
        guard let start = rangeStart(header) else {
            return false
        }
        return start > 0 && start < Self.blob.count
    }

    @Test func resumesWithRangeAfterDroppedConnection() async throws {
        let result = try await fetch(drops: 2, honorRange: true)
        #expect(result.digest.digestString == Self.descriptor.digest)
        #expect(result.data == Data(Self.blob))
        try #require(result.ranges.count == 3)
        #expect(result.ranges[0] == nil)
        #expect(result.ranges.dropFirst().allSatisfy(isResume))
    }

    @Test func restartsWhenRegistryIgnoresRange() async throws {
        let result = try await fetch(drops: 1, honorRange: false)
        #expect(result.digest.digestString == Self.descriptor.digest)
        #expect(result.data == Data(Self.blob))
        try #require(result.ranges.count == 2)
        #expect(result.ranges[0] == nil)
        #expect(isResume(result.ranges[1]))
    }

    @Test func failsWithoutRetryOptions() async throws {
        let server = try await BlobStubServer.start(blob: Self.blob, drops: 1, honorRange: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        let client = RegistryClient(host: "127.0.0.1", scheme: "http", port: server.port)
        await #expect(throws: (any Error).self) {
            _ = try await client.fetchBlob(name: "test/image", descriptor: Self.descriptor, into: file, progress: nil)
        }
        #expect(server.rangeHeaders == [nil])
        try await server.shutdown()
    }

    @Test func sendsNoRangeWithoutDrops() async throws {
        let result = try await fetch(drops: 0, honorRange: true)
        #expect(result.data == Data(Self.blob))
        #expect(result.ranges == [nil])
    }
}
