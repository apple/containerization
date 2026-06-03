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

// Adapted from https://github.com/apple/swift-nio-examples/tree/main/connect-proxy

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A lightweight HTTP proxy that runs on the host and filters by hostname.
///
/// Binds to the host's gateway IP on a vmnet host-only network. Workload containers
/// that have no direct internet route use this proxy (via HTTP_PROXY/HTTPS_PROXY env vars)
/// to reach the outside world. Only hostnames matching the allowlist are permitted.
///
/// Handles both HTTPS (via CONNECT tunneling) and plain HTTP (via request forwarding).
/// For HTTPS, the client sends a CONNECT request with the target hostname in plaintext
/// before TLS begins, so we can filter without any certificate interception.
final class HostProxy: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel

    /// The port the proxy is listening on.
    let port: Int

    /// The host address the proxy is bound to.
    let host: String

    /// Start a proxy bound to the given address.
    /// - Parameters:
    ///   - host: IP address to bind to (e.g. the vmnet gateway IP).
    ///   - port: Port to bind to. Use 0 for an OS-assigned port.
    ///   - allowedHosts: Hostname patterns to allow. Supports `*.example.com` wildcards.
    init(host: String, port: Int = 0, allowedHosts: [String]) async throws {
        self.host = host
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                    )
                    try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
                    try channel.pipeline.syncOperations.addHandler(
                        ConnectHandler(allowedHosts: allowedHosts)
                    )
                }
            }

        let channel = try await bootstrap.bind(
            to: SocketAddress(ipAddress: host, port: port)
        ).get()

        guard let localAddress = channel.localAddress, let assignedPort = localAddress.port else {
            throw SandboxyError.proxyFailed(reason: "could not determine proxy listen port")
        }

        self.port = assignedPort
        self.channel = channel
    }

    /// Stop the proxy and release resources.
    func stop() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
    }

    /// Check if a hostname matches any pattern in the allowlist.
    static func isAllowed(host: String, allowedHosts: [String]) -> Bool {
        let host = host.lowercased()
        for pattern in allowedHosts {
            let pattern = pattern.lowercased()
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1))  // e.g. ".example.com"
                if host == String(pattern.dropFirst(2)) || host.hasSuffix(suffix) {
                    return true
                }
            } else if host == pattern {
                return true
            }
        }
        return false
    }
}

/// Channel handler that processes HTTP CONNECT and plain HTTP proxy requests.
/// Checks the target hostname against an allowlist before connecting.
private final class ConnectHandler {
    private var upgradeState: State
    private let allowedHosts: [String]

    /// Buffered request for plain HTTP forwarding (nil for CONNECT).
    private var pendingHTTPHead: HTTPRequestHead?
    private var pendingHTTPBody: [ByteBuffer] = []

    init(allowedHosts: [String]) {
        self.upgradeState = .idle
        self.allowedHosts = allowedHosts
    }
}

extension ConnectHandler {
    fileprivate enum State {
        case idle
        case beganConnecting
        case awaitingEnd(connectResult: Channel)
        case awaitingConnection(pendingBytes: [NIOAny])
        case upgradeComplete(pendingBytes: [NIOAny])
        case upgradeFailed
    }
}

extension ConnectHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.upgradeState {
        case .idle:
            self.handleInitialMessage(context: context, data: self.unwrapInboundIn(data))

        case .beganConnecting:
            switch self.unwrapInboundIn(data) {
            case .body(let body):
                self.pendingHTTPBody.append(body)
            case .end:
                self.upgradeState = .awaitingConnection(pendingBytes: [])
                self.removeDecoder(context: context)
            default:
                break
            }

        case .awaitingEnd(let peerChannel):
            switch self.unwrapInboundIn(data) {
            case .body(let body):
                self.pendingHTTPBody.append(body)
            case .end:
                self.upgradeState = .upgradeComplete(pendingBytes: [])
                self.removeDecoder(context: context)
                self.glue(peerChannel, context: context)
            default:
                break
            }

        case .awaitingConnection(var pendingBytes):
            self.upgradeState = .awaitingConnection(pendingBytes: [])
            pendingBytes.append(data)
            self.upgradeState = .awaitingConnection(pendingBytes: pendingBytes)

        case .upgradeComplete(var pendingBytes):
            self.upgradeState = .upgradeComplete(pendingBytes: [])
            pendingBytes.append(data)
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)

        case .upgradeFailed:
            break
        }
    }
}

extension ConnectHandler: RemovableChannelHandler {
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        var didRead = false

        while case .upgradeComplete(var pendingBytes) = self.upgradeState, pendingBytes.count > 0 {
            self.upgradeState = .upgradeComplete(pendingBytes: [])
            let nextRead = pendingBytes.removeFirst()
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)

            context.fireChannelRead(nextRead)
            didRead = true
        }

        if didRead {
            context.fireChannelReadComplete()
        }

        context.leavePipeline(removalToken: removalToken)
    }
}

extension ConnectHandler {
    private func handleInitialMessage(context: ChannelHandlerContext, data: InboundIn) {
        guard case .head(let head) = data else {
            self.httpErrorAndClose(context: context, status: .badRequest)
            return
        }

        if head.method == .CONNECT {
            // HTTPS: CONNECT host:port
            let components = head.uri.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let host = String(components.first!)
            let port = components.last.flatMap { Int($0, radix: 10) } ?? 443

            guard HostProxy.isAllowed(host: host, allowedHosts: self.allowedHosts) else {
                self.httpErrorAndClose(context: context, status: .forbidden)
                return
            }

            self.upgradeState = .beganConnecting
            self.connectTo(host: host, port: port, context: context)
        } else {
            // Plain HTTP: GET http://host/path, POST http://host/path, etc.
            guard let url = URLComponents(string: head.uri),
                let hostname = url.host, !hostname.isEmpty
            else {
                self.httpErrorAndClose(context: context, status: .badRequest)
                return
            }

            guard HostProxy.isAllowed(host: hostname, allowedHosts: self.allowedHosts) else {
                self.httpErrorAndClose(context: context, status: .forbidden)
                return
            }

            let port = url.port ?? 80

            // Rewrite URI from absolute (http://host/path) to relative (/path).
            var relativePath = url.path
            if relativePath.isEmpty { relativePath = "/" }
            if let query = url.query {
                relativePath += "?\(query)"
            }

            var rewritten = head
            rewritten.uri = relativePath
            self.pendingHTTPHead = rewritten

            self.upgradeState = .beganConnecting
            self.connectTo(host: hostname, port: port, context: context)
        }
    }

    private func connectTo(host: String, port: Int, context: ChannelHandlerContext) {
        ClientBootstrap(group: context.eventLoop)
            .connect(host: host, port: port).assumeIsolatedUnsafeUnchecked().whenComplete { result in
                switch result {
                case .success(let channel):
                    self.connectSucceeded(channel: channel, context: context)
                case .failure(let error):
                    self.connectFailed(error: error, context: context)
                }
            }
    }

    private func connectSucceeded(channel: Channel, context: ChannelHandlerContext) {
        switch self.upgradeState {
        case .beganConnecting:
            self.upgradeState = .awaitingEnd(connectResult: channel)

        case .awaitingConnection(let pendingBytes):
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)
            self.glue(channel, context: context)

        case .awaitingEnd(let peerChannel):
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)

        case .idle, .upgradeFailed, .upgradeComplete:
            context.close(promise: nil)
        }
    }

    private func connectFailed(error: Error, context: ChannelHandlerContext) {
        switch self.upgradeState {
        case .beganConnecting, .awaitingConnection:
            self.httpErrorAndClose(context: context, status: .badGateway)

        case .awaitingEnd(let peerChannel):
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)

        case .idle, .upgradeFailed, .upgradeComplete:
            context.close(promise: nil)
        }

        context.fireErrorCaught(error)
    }

    private func glue(_ peerChannel: Channel, context: ChannelHandlerContext) {
        if let httpHead = self.pendingHTTPHead {
            // Plain HTTP: forward the buffered request to the peer, then glue.
            var buffer = context.channel.allocator.buffer(capacity: 256)
            buffer.writeString("\(httpHead.method) \(httpHead.uri) HTTP/\(httpHead.version.major).\(httpHead.version.minor)\r\n")
            for (name, value) in httpHead.headers {
                buffer.writeString("\(name): \(value)\r\n")
            }
            buffer.writeString("\r\n")
            for var body in self.pendingHTTPBody {
                buffer.writeBuffer(&body)
            }
            peerChannel.writeAndFlush(buffer, promise: nil)
            self.pendingHTTPHead = nil
            self.pendingHTTPBody = []
        } else {
            // CONNECT: send 200 OK to the client.
            // Content-Length: 0 prevents the encoder from adding chunked transfer encoding,
            // which would inject a chunked terminator into the raw tunnel and break TLS.
            let headers = HTTPHeaders([("Content-Length", "0")])
            let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: headers)
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }

        self.removeEncoder(context: context)

        let (localGlue, peerGlue) = GlueHandler.matchedPair()
        do {
            try context.channel.pipeline.syncOperations.addHandler(localGlue)
            try peerChannel.pipeline.syncOperations.addHandler(peerGlue)
            context.pipeline.syncOperations.removeHandler(self, promise: nil)
        } catch {
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)
        }
    }

    private func httpErrorAndClose(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        self.upgradeState = .upgradeFailed

        let headers = HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: status, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).assumeIsolatedUnsafeUnchecked().whenComplete {
            (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
    }

    private func removeDecoder(context: ChannelHandlerContext) {
        if let ctx = try? context.pipeline.syncOperations.context(
            handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self
        ) {
            context.pipeline.syncOperations.removeHandler(context: ctx, promise: nil)
        }
    }

    private func removeEncoder(context: ChannelHandlerContext) {
        if let ctx = try? context.pipeline.syncOperations.context(
            handlerType: HTTPResponseEncoder.self
        ) {
            context.pipeline.syncOperations.removeHandler(context: ctx, promise: nil)
        }
    }
}

/// Bidirectional relay handler that glues two channels together.
private final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead: Bool = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }
}

extension GlueHandler {
    fileprivate func partnerWrite(_ data: NIOAny) {
        self.context?.write(data, promise: nil)
    }

    fileprivate func partnerFlush() {
        self.context?.flush()
    }

    fileprivate func partnerWriteEOF() {
        self.context?.close(mode: .output, promise: nil)
    }

    fileprivate func partnerCloseFull() {
        self.context?.close(promise: nil)
    }

    fileprivate func partnerBecameWritable() {
        if self.pendingRead {
            self.pendingRead = false
            self.context?.read()
        }
    }

    fileprivate var partnerWritable: Bool {
        self.context?.channel.isWritable ?? false
    }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            self.partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            self.partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner = self.partner, partner.partnerWritable {
            context.read()
        } else {
            self.pendingRead = true
        }
    }
}
