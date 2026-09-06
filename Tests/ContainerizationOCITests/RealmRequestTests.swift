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

#if os(macOS)

import ContainerizationError
import ContainerizationExtras
import Crypto
import Foundation
import NIO
import NIOSSL
import Network
import Testing
import X509

@testable import ContainerizationOCI

private final class SeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }
}

private let basicChallenge =
    "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"Registry Realm\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

/// Records request heads and replies with a canned response. One request per connection.
private final class RecordingHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private let respond: @Sendable (_ requestHead: String) -> String
    private let seenBox = SeenBox()

    var seen: [String] { seenBox.all }

    private init(listener: NWListener, respond: @escaping @Sendable (String) -> String) {
        self.listener = listener
        self.respond = respond
    }

    static func start(respond: @escaping @Sendable (String) -> String) throws -> RecordingHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = RecordingHTTPServer(listener: listener, respond: respond)
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { sem.signal() }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                server.seenBox.append(head)
                let body = server.respond(head)
                conn.send(content: body.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global())
        _ = sem.wait(timeout: .now() + 5)
        server.port = listener.port?.rawValue ?? 0
        return server
    }

    func stop() { listener.cancel() }
}

/// TLS variant, required because the client only sends credentials over https.
private final class RecordingTLSServer: @unchecked Sendable {
    private let group: EventLoopGroup
    private let channel: Channel
    let port: Int
    private let seenBox: SeenBox

    var seen: [String] { seenBox.all }

    private init(group: EventLoopGroup, channel: Channel, port: Int, seenBox: SeenBox) {
        self.group = group
        self.channel = channel
        self.port = port
        self.seenBox = seenBox
    }

    static func start(respond: @escaping @Sendable (_ requestHead: String) -> String) throws -> RecordingTLSServer {
        let identity = try Self.makeEphemeralIdentity()
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(identity.certificate)], privateKey: .privateKey(identity.privateKey))
        tls.applicationProtocols = ["http/1.1"]
        let sslContext = try NIOSSLContext(configuration: tls)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let seenBox = SeenBox()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.pipeline.addHandler(RawResponder(seenBox: seenBox, respond: respond))
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        guard let port = channel.localAddress?.port else {
            throw ContainerizationError(.internalError, message: "no bound port")
        }
        return RecordingTLSServer(group: group, channel: channel, port: port, seenBox: seenBox)
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }

    private final class RawResponder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private let seenBox: SeenBox
        private let respond: @Sendable (String) -> String

        init(seenBox: SeenBox, respond: @escaping @Sendable (String) -> String) {
            self.seenBox = seenBox
            self.respond = respond
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = self.unwrapInboundIn(data)
            let head = buffer.readString(length: buffer.readableBytes) ?? ""
            seenBox.append(head)
            let channel = context.channel
            channel.writeAndFlush(channel.allocator.buffer(string: respond(head))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }

    private static func makeEphemeralIdentity() throws -> (certificate: NIOSSLCertificate, privateKey: NIOSSLPrivateKey) {
        let certificateKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let subject = try DistinguishedName { CommonName("localhost") }
        let now = Date()

        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certificateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(60 * 60),
            issuer: subject,
            subject: subject,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: certificateKey
        )

        return (
            try NIOSSLCertificate(bytes: certificate.serializeAsPEM().derBytes, format: .der),
            try NIOSSLPrivateKey(bytes: certificateKey.serializeAsPEM().derBytes, format: .der)
        )
    }
}

/// A registry must not be able to aim the token fetch at a host of its choosing.
struct RealmRequestTests {
    /// A proxy resolved at init would intercept the loopback servers these tests assert on.
    static var loopbackIsDirect: Bool {
        ProxyUtils.proxyFromEnvironment(scheme: "http", host: "127.0.0.1") == nil
            && ProxyUtils.proxyFromEnvironment(scheme: "https", host: "127.0.0.1") == nil
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: loopbackIsDirect))
    func maliciousRealmIsNeitherFollowedNorCredentialed() async throws {
        let secret = "INTERNAL_SECRET_TOKEN_\(UUID().uuidString)"

        let internalSvc = try RecordingHTTPServer.start { _ in
            let json = "{\"access_token\":\"\(secret)\"}"
            return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        }
        defer { internalSvc.stop() }

        let realm = "http://127.0.0.1:\(internalSvc.port)/token"
        let registry = try RecordingHTTPServer.start { head in
            if head.contains("Authorization: Bearer ") {
                return "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            let challenge = "Bearer realm=\"\(realm)\",service=\"evil\""
            return "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: \(challenge)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        defer { registry.stop() }

        let client = RegistryClient(
            host: "127.0.0.1",
            scheme: "http",
            port: Int(registry.port),
            authentication: BasicAuthentication(username: "deploy", password: "s3cr3t-p@ss")
        )
        let error = await #expect(throws: RegistryClient.Error.self) { try await client.ping() }
        guard case .insecureCredentialExchange = error else {
            Issue.record("expected insecureCredentialExchange, got \(String(describing: error))")
            return
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(internalSvc.seen.isEmpty, "no request may be issued to the attacker-chosen realm host")

        let basic = "Basic " + Data("deploy:s3cr3t-p@ss".utf8).base64EncodedString()
        #expect(!internalSvc.seen.contains { $0.contains(basic) }, "credentials must never reach the realm host")
        #expect(!registry.seen.contains { $0.contains(basic) }, "credentials must never reach the registry")
        #expect(!registry.seen.contains { $0.contains("Authorization: Bearer \(secret)") }, "no token may be reflected to the registry")
    }

    /// Not gated: the realm is rejected before any socket opens, so no proxy is involved.
    @Test(arguments: [
        "http://169.254.169.254/latest/meta-data/",
        "http://localhost/token",
        "http://10.0.0.5/token",
        "https://auth.attacker.com/token",
    ])
    func realmIsRejectedBeforeAnyRequestIsIssued(realmHost: String) async throws {
        let internalSvc = try RecordingHTTPServer.start { _ in
            let json = "{\"access_token\":\"LEAKED\"}"
            return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        }
        defer { internalSvc.stop() }

        // Aim each realm at the live port, so a followed realm would be recorded.
        var components = try #require(URLComponents(string: realmHost))
        components.host = "127.0.0.1"
        components.port = Int(internalSvc.port)
        let realm = try #require(components.string)

        let client = RegistryClient(
            host: "registry.example.com",
            authentication: BasicAuthentication(username: "deploy", password: "s3cr3t-p@ss")
        )
        let request = TokenRequest(realm: realm, service: "evil", clientId: "tests", scope: nil)
        let error = await #expect(throws: RegistryClient.Error.self) { try await client.fetchToken(request: request) }
        guard case .insecureCredentialExchange = error else {
            Issue.record("expected insecureCredentialExchange, got \(String(describing: error))")
            return
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(internalSvc.seen.isEmpty, "no request may be issued to the attacker-chosen realm host")
    }

    private static func insecureTLSClient(port: Int, authentication: Authentication?) -> RegistryClient {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        return RegistryClient(host: "127.0.0.1", scheme: "https", port: port, authentication: authentication, retryOptions: nil, tlsConfiguration: tls)
    }

    /// The `registry:3` shape: Basic challenge, no Bearer.
    @Test(.timeLimit(.minutes(1)), .enabled(if: loopbackIsDirect))
    func basicChallengeIsAnsweredOnceOverTLS() async throws {
        let registry = try RecordingTLSServer.start { head in
            if head.contains("Authorization: Basic ") {
                return "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            return basicChallenge
        }
        defer { registry.stop() }

        let client = Self.insecureTLSClient(port: registry.port, authentication: BasicAuthentication(username: "deploy", password: "s3cr3t-p@ss"))
        try await client.ping()

        let basic = "Basic " + Data("deploy:s3cr3t-p@ss".utf8).base64EncodedString()
        #expect(registry.seen.count == 2, "expected one unauthenticated request and exactly one retry")
        #expect(registry.seen.first?.contains("Authorization") == false, "credentials must not be sent before the challenge")
        #expect(registry.seen.last?.contains(basic) == true, "the retry must carry the Basic credentials")
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: loopbackIsDirect))
    func rejectedBasicCredentialsDoNotRetryForever() async throws {
        let registry = try RecordingTLSServer.start { _ in
            basicChallenge
        }
        defer { registry.stop() }

        let client = Self.insecureTLSClient(port: registry.port, authentication: BasicAuthentication(username: "deploy", password: "wrong"))
        let error = await #expect(throws: RegistryClient.Error.self) { try await client.ping() }
        guard case .invalidStatus(_, let status, _) = error else {
            Issue.record("expected invalidStatus, got \(String(describing: error))")
            return
        }
        #expect(status == .unauthorized)
        #expect(registry.seen.count == 2, "expected exactly one retry before failing")
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: loopbackIsDirect))
    func basicChallengeWithoutCredentialsFails() async throws {
        let registry = try RecordingTLSServer.start { _ in
            basicChallenge
        }
        defer { registry.stop() }

        let client = Self.insecureTLSClient(port: registry.port, authentication: nil)
        _ = await #expect(throws: RegistryClient.Error.self) { try await client.ping() }
        #expect(registry.seen.count == 1, "an unauthenticated client must not retry")
    }
}

#endif
