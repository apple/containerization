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
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

extension CloudHypervisor {
    /// A high-level client for Cloud Hypervisor's REST API over a Unix Domain Socket.
    ///
    /// Use ``init(socketPath:eventLoopGroup:logger:)`` to construct a client, then
    /// call endpoint-specific methods (added as extensions in `Endpoints/`).
    ///
    /// The internal `get(_:)` / `put(_:)` / `put(_:body:)` helpers are used by
    /// endpoint extensions in A8-A10 and are intentionally not public.
    public final class Client: Sendable {
        private let http: HTTPOverUDSClient
        private let group: any EventLoopGroup
        private let ownsGroup: Bool
        private let encoder: JSONEncoder
        private let decoder: JSONDecoder

        /// Create a client that communicates with Cloud Hypervisor over the given socket.
        ///
        /// - Parameters:
        ///   - socketPath: A `file://` URL whose `.path` points to the socket.
        ///   - eventLoopGroup: The NIO event loop group to use. When `nil` the client
        ///     creates and owns its own group. Callers wanting deterministic
        ///     resource release should pass a group they manage and call
        ///     ``shutdown()`` themselves; the deinit fallback shuts down
        ///     asynchronously and may outlive the `Client` instance briefly.
        ///   - logger: Logger for transport-level diagnostics.
        ///   - requestTimeout: Per-request deadline. A request that does not
        ///     complete within this window fails with
        ///     ``CloudHypervisor/Error/transport(_:)``. Defaults to 30 seconds.
        /// - Throws: ``CloudHypervisor/Error/invalidSocketPath(_:)`` when `socketPath`
        ///   is not a `file://` URL.
        public init(
            socketPath: URL,
            eventLoopGroup: (any EventLoopGroup)? = nil,
            logger: Logger = Logger(label: "CloudHypervisor.Client"),
            requestTimeout: TimeAmount = .seconds(30)
        ) throws {
            guard socketPath.isFileURL else {
                throw CloudHypervisor.Error.invalidSocketPath(socketPath.absoluteString)
            }
            if let eventLoopGroup {
                self.ownsGroup = false
                self.group = eventLoopGroup
            } else {
                self.ownsGroup = true
                self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            }
            self.http = HTTPOverUDSClient(
                socketPath: socketPath.path,
                group: self.group,
                logger: logger,
                requestTimeout: requestTimeout
            )
            self.encoder = JSONEncoder()
            self.decoder = JSONDecoder()
        }

        /// Drain the underlying `AsyncHTTPClient`, and shut down the NIO
        /// event-loop group when this client owns it. Idempotent. Prefer
        /// calling this explicitly over relying on the deinit fallback —
        /// `shutdown()` waits for in-flight I/O to drain.
        ///
        /// Callers that pass in a shared `eventLoopGroup` MUST call this
        /// before tearing down that group. AsyncHTTPClient parks deferred
        /// connection-close work on the group's event loops after each
        /// response returns; shutting the group down before that work
        /// runs trips NIO's "Cannot schedule tasks on an EventLoop that
        /// has already shut down" warning (and a forced crash in future
        /// NIO releases).
        public func shutdown() async throws {
            try await http.shutdown()
            if ownsGroup {
                try await group.shutdownGracefully()
            }
        }

        deinit {
            // Use the async-dispatched shutdown rather than
            // `syncShutdownGracefully()`. The sync variant blocks the calling
            // thread until every event loop drains, which deadlocks if deinit
            // happens to run on one of the group's event loop threads (e.g.
            // the last release came from inside a NIO callback). The
            // callback-based variant schedules shutdown on its own queue and
            // returns immediately — at the cost of giving up any signal that
            // shutdown completed. Callers who need that signal should call
            // `shutdown()` explicitly before letting the client deinit.
            if ownsGroup {
                group.shutdownGracefully(queue: .global()) { _ in }
            }
        }

        // MARK: - Internal request dispatch helpers
        //
        // Endpoint extensions (A8/A9/A10) call these to build their public API.
        // They are internal (not public) because all public surface lives in those
        // extensions.

        /// GET `path`, decode the response body as `Response`.
        func get<Response: Decodable & Sendable>(_ path: String) async throws -> Response {
            try await sendAndDecode(method: .GET, path: path, body: nil)
        }

        /// PUT `path` with no body, discard the response.
        func put(_ path: String) async throws {
            try await sendVoid(method: .PUT, path: path, body: nil)
        }

        /// PUT `path` with a JSON-encoded body, discard the response.
        func put<Body: Encodable & Sendable>(_ path: String, body: Body) async throws {
            let data = try encoder.encode(body)
            try await sendVoid(method: .PUT, path: path, body: data)
        }

        /// PUT `path` with a JSON-encoded body, decode the response as `Response`.
        func put<Body: Encodable & Sendable, Response: Decodable & Sendable>(
            _ path: String,
            body: Body
        ) async throws -> Response {
            let data = try encoder.encode(body)
            return try await sendAndDecode(method: .PUT, path: path, body: data)
        }

        // MARK: - Private machinery

        private func sendAndDecode<Response: Decodable & Sendable>(
            method: HTTPMethod,
            path: String,
            body: Data?
        ) async throws -> Response {
            let resp = try await http.send(method: method, uri: path, body: body)
            guard (200..<300).contains(Int(resp.status.code)) else {
                throw CloudHypervisor.Error.http(status: resp.status, body: resp.body)
            }
            do {
                return try decoder.decode(Response.self, from: resp.body)
            } catch {
                throw CloudHypervisor.Error.decoding(error, body: resp.body)
            }
        }

        private func sendVoid(method: HTTPMethod, path: String, body: Data?) async throws {
            let resp = try await http.send(method: method, uri: path, body: body)
            guard (200..<300).contains(Int(resp.status.code)) else {
                throw CloudHypervisor.Error.http(status: resp.status, body: resp.body)
            }
        }
    }
}
