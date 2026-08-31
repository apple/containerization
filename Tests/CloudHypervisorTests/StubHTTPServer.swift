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
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - StubRequest / StubResponse

/// An inbound HTTP request captured by the stub server.
struct StubRequest: Sendable {
    let method: HTTPMethod
    let uri: String
    let body: Data
    let headers: HTTPHeaders
}

/// A canned HTTP response produced by the stub server.
struct StubResponse: Sendable {
    let status: HTTPResponseStatus
    let body: Data
    let headers: HTTPHeaders

    static func ok(_ body: Data = .init()) -> StubResponse {
        StubResponse(status: .ok, body: body, headers: [:])
    }

    static func json<T: Encodable>(_ value: T) throws -> StubResponse {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        return StubResponse(status: .ok, body: data, headers: headers)
    }

    static func status(_ status: HTTPResponseStatus, body: Data = .init()) -> StubResponse {
        StubResponse(status: status, body: body, headers: [:])
    }
}

// MARK: - StubHTTPServer

/// An in-process HTTP/1.1 server bound to a Unix Domain Socket, used in tests.
///
/// Example:
/// ```swift
/// let server = try await StubHTTPServer(eventLoopGroup: group) { req in
///     return StubResponse.ok(Data("{}".utf8))
/// }
/// defer { Task { try? await server.shutdown() } }
/// ```
final class StubHTTPServer: Sendable {
    /// The path to the Unix Domain Socket this server is bound to.
    let socketPath: String

    private let channel: Channel
    /// Recorded requests, protected by a lock so the test thread can read safely.
    private let requests: NIOLockedValueBox<[StubRequest]>

    init(
        eventLoopGroup: any EventLoopGroup,
        handler: @escaping @Sendable (StubRequest) -> StubResponse
    ) async throws {
        let sockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ch-stub-\(UUID().uuidString).sock")
            .path

        let requestsBox = NIOLockedValueBox<[StubRequest]>([])

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withPipeliningAssistance: false
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        StubRequestHandler(userHandler: handler, requests: requestsBox)
                    )
                }
            }

        let boundChannel =
            try await bootstrap
            .bind(unixDomainSocketPath: sockPath, cleanupExistingSocketFile: true)
            .get()

        self.socketPath = sockPath
        self.channel = boundChannel
        self.requests = requestsBox
    }

    /// Stop accepting connections and close the listening socket.
    func shutdown() async throws {
        try await channel.close().get()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Returns all requests recorded so far.
    func recordedRequests() -> [StubRequest] {
        requests.withLockedValue { $0 }
    }
}

// MARK: - StubRequestHandler

/// Handles a single inbound HTTP/1.1 request, invokes the user handler, and
/// writes the stub response.
///
/// All ChannelHandler callbacks run on the channel's event loop, so the mutable
/// inbound-state fields need no external synchronisation. The shared `requests`
/// box is still locked because the test thread reads it from outside the loop.
private final class StubRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let userHandler: @Sendable (StubRequest) -> StubResponse
    private let requests: NIOLockedValueBox<[StubRequest]>

    // Mutable inbound state — only touched on the event loop.
    private var pendingMethod: HTTPMethod?
    private var pendingURI: String?
    private var pendingHeaders: HTTPHeaders = [:]
    private var pendingBody: [UInt8] = []

    init(
        userHandler: @escaping @Sendable (StubRequest) -> StubResponse,
        requests: NIOLockedValueBox<[StubRequest]>
    ) {
        self.userHandler = userHandler
        self.requests = requests
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingMethod = head.method
            pendingURI = head.uri
            pendingHeaders = head.headers
            pendingBody = []
        case .body(var buf):
            if let bytes = buf.readBytes(length: buf.readableBytes) {
                pendingBody.append(contentsOf: bytes)
            }
        case .end:
            guard let method = pendingMethod, let uri = pendingURI else {
                context.close(promise: nil)
                return
            }
            let request = StubRequest(
                method: method,
                uri: uri,
                body: Data(pendingBody),
                headers: pendingHeaders
            )
            requests.withLockedValue { $0.append(request) }
            let stubResp = userHandler(request)
            writeResponse(context: context, response: stubResp)
        }
    }

    private func writeResponse(context: ChannelHandlerContext, response: StubResponse) {
        var respHeaders = response.headers
        respHeaders.replaceOrAdd(name: "Content-Length", value: "\(response.body.count)")
        respHeaders.replaceOrAdd(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: respHeaders)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        if !response.body.isEmpty {
            var buf = context.channel.allocator.buffer(capacity: response.body.count)
            buf.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }

        // Use NIOLoopBound to safely capture `context` in a @Sendable closure.
        // The bound asserts event-loop access; the close runs on the same loop
        // as the flush completion, which is correct.
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            boundContext.value.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
