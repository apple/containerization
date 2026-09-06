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
import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import ContainerizationOCI

/// `RegistryClient` honours `HTTP_PROXY` from the environment, which would
/// divert a request aimed at the in-process stub below. Skip rather than fail
/// when a proxy is configured and does not exempt loopback.
private var reachesLoopbackDirectly: Bool {
    let env = ProcessInfo.processInfo.environment
    guard (env["HTTP_PROXY"] ?? env["http_proxy"]) != nil else {
        return true
    }
    let noProxy = env["NO_PROXY"] ?? env["no_proxy"] ?? ""
    return noProxy.split(separator: ",").contains {
        let entry = $0.trimmingCharacters(in: .whitespaces)
        return entry == "127.0.0.1" || entry == "*"
    }
}

/// Serves one canned HEAD response on loopback and reports the port it bound.
private final class HeaderStubServer: Sendable {
    let port: Int
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup

    static func start(digest: String?) async throws -> HeaderStubServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
                    try channel.pipeline.syncOperations.addHandler(Handler(digest: digest))
                }
            }

        do {
            let bound = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            guard let port = bound.localAddress?.port else {
                try? await bound.close().get()
                throw ContainerizationError(.internalError, message: "stub server bound without a port")
            }
            return HeaderStubServer(port: port, channel: bound, group: group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private init(port: Int, channel: Channel, group: MultiThreadedEventLoopGroup) {
        self.port = port
        self.channel = channel
        self.group = group
    }

    func shutdown() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let digest: String?

        init(digest: String?) {
            self.digest = digest
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .end = unwrapInboundIn(data) else {
                return
            }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: MediaTypes.imageManifest)
            // A HEAD response advertises the length the body would have had.
            headers.add(name: "Content-Length", value: "512")
            headers.add(name: "Connection", value: "close")
            if let digest {
                headers.add(name: "Docker-Content-Digest", value: digest)
            }

            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)

            // Bind the context so the completion callback, which runs on this
            // same event loop, can close the channel.
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                boundContext.value.close(promise: nil)
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }
}

/// `resolve` assembles its `Descriptor` out of response headers rather than out
/// of a JSON body, so `Descriptor`'s decoder — which is what rejects a
/// traversing digest everywhere else — never runs on it. These tests drive the
/// real client against a loopback server answering HEAD with a chosen
/// `Docker-Content-Digest`.
@Suite(.enabled(if: reachesLoopbackDirectly))
struct ResolveDigestHeaderTests {
    private static let valid = "sha256:\(String(repeating: "a", count: 64))"

    private func resolve(digestHeader: String?) async throws -> Descriptor {
        let server = try await HeaderStubServer.start(digest: digestHeader)
        do {
            // Retry options are left off so a rejected digest fails on the first
            // response rather than being replayed.
            let client = RegistryClient(host: "127.0.0.1", scheme: "http", port: server.port)
            let descriptor = try await client.resolve(name: "test/image", tag: "latest")
            try await server.shutdown()
            return descriptor
        } catch {
            try? await server.shutdown()
            throw error
        }
    }

    @Test func acceptsWellFormedDigestHeader() async throws {
        let descriptor = try await resolve(digestHeader: Self.valid)
        #expect(descriptor.digest == Self.valid)
        #expect(descriptor.mediaType == MediaTypes.imageManifest)
        #expect(descriptor.size == 512)
    }

    /// The descriptor `resolve` returns is the root of a pull: its digest becomes
    /// a URL path segment on the follow-up GET and a content store path component
    /// once the blob lands. A registry — or anything answering as one — must not
    /// be able to put `../` in it.
    @Test(arguments: [
        "sha256:../../../../etc/hosts",
        "sha256:" + String(repeating: "../", count: 64) + "etc/hosts",
        "../../etc/hosts",
        // Bare hex is a usable store path component but not a valid descriptor
        // digest: `fetch` would GET /v2/<name>/manifests/<hex> with no algorithm.
        String(repeating: "a", count: 64),
        "sha256:",
        "",
        "sha256:\(String(repeating: "A", count: 64))",
        "sha512:\(String(repeating: "a", count: 128))",
        "sha256:\(String(repeating: "a", count: 63))",
    ])
    func rejectsMalformedDigestHeader(_ digest: String) async throws {
        await #expect(throws: ContainerizationError.self) {
            try await resolve(digestHeader: digest)
        }
    }

    @Test func rejectsMissingDigestHeader() async throws {
        await #expect(throws: ContainerizationError.self) {
            try await resolve(digestHeader: nil)
        }
    }
}
