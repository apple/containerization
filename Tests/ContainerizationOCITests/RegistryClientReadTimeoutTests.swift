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

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import ContainerizationOCI

/// A registry that stops sending a response body partway through must not hang the client.
@Suite("RegistryClient read timeout")
struct RegistryClientReadTimeoutTests {
    private static let group = MultiThreadedEventLoopGroup.singleton

    private enum Outcome {
        case finished(Result<Void, any Error>)
        case stillWaiting
    }

    @Test("fetchBlob fails with a read timeout when the body stalls")
    func fetchBlobFailsWhenBodyStalls() async throws {
        let server = try await StallingServer.start(group: Self.group)
        defer { Task { try? await server.close().get() } }
        let port = try #require(server.localAddress?.port)

        let client = RegistryClient(host: "127.0.0.1", scheme: "http", port: port, readTimeout: .milliseconds(500))
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageLayerGzip,
            digest: "sha256:" + String(repeating: "a", count: 64),
            size: Int64(StallingServer.declaredLength)
        )

        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    try await client.fetchBlob(name: "stalled/image", descriptor: descriptor) { _, body in
                        for try await _ in body {}
                    }
                    return .finished(.success(()))
                } catch {
                    return .finished(.failure(error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return .stillWaiting
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        guard case .finished(.failure(let error)) = outcome else {
            Issue.record("expected the stalled download to fail, got \(outcome)")
            return
        }
        #expect(error as? HTTPClientError == .readTimeout)
    }
}

/// Answers every request with a response head and the first few body bytes, then sends nothing more.
private enum StallingServer {
    static let declaredLength = 1024

    static func start(group: any EventLoopGroup) async throws -> any Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
                    try channel.pipeline.syncOperations.addHandler(Handler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    private final class Handler: ChannelInboundHandler, Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .end = unwrapInboundIn(data) else { return }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: MediaTypes.imageLayerGzip)
            headers.add(name: "Content-Length", value: "\(StallingServer.declaredLength)")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            let partial = context.channel.allocator.buffer(repeating: 0, count: 16)
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(partial))), promise: nil)
        }
    }
}
