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
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

// MARK: - HTTPResponse

/// An HTTP response received from Cloud Hypervisor's REST API.
struct HTTPResponse: Sendable {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: Data
}

// MARK: - HTTPOverUDSClient

/// A minimal HTTP/1.1 client that speaks over a Unix Domain Socket. Backed
/// by `AsyncHTTPClient` so connection lifecycle, timeout handling, and the
/// head/body/end write race we used to manage manually all live in the
/// library rather than in this file.
///
/// AHC selects UDS via the `http+unix://` URL scheme (the supplied
/// `URL(httpURLWithSocketPath:uri:)` initializer does the percent-encoding).
/// Each `HTTPOverUDSClient` owns a fresh `HTTPClient` configured with
/// `eventLoopGroupProvider: .shared(group)` so the underlying NIO group is
/// the caller's to shut down — `httpClient.shutdown` only releases the
/// client's own state.
final class HTTPOverUDSClient: Sendable {
    private let socketPath: String
    private let httpClient: HTTPClient
    private let logger: Logger
    private let requestTimeout: TimeAmount
    // One-shot flag tracking whether shutdown has been initiated, so
    // explicit `shutdown()` is idempotent and `deinit` skips its fallback
    // when an explicit shutdown already drained the HTTPClient.
    private let didShutdown: NIOLockedValueBox<Bool>

    init(
        socketPath: String,
        group: any EventLoopGroup,
        logger: Logger,
        requestTimeout: TimeAmount = .seconds(30)
    ) {
        self.socketPath = socketPath
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(group),
            configuration: .init()
        )
        self.logger = logger
        self.requestTimeout = requestTimeout
        self.didShutdown = NIOLockedValueBox(false)
    }

    /// Drain the underlying HTTPClient and wait for in-flight I/O to
    /// finish. Idempotent — safe to call multiple times.
    ///
    /// MUST be called before the shared event-loop group is torn down.
    /// AsyncHTTPClient leaves deferred connection-cleanup work parked on
    /// the group's event loops after a response returns; if the group is
    /// shut down first, that deferred work fails to schedule and SwiftNIO
    /// prints "Cannot schedule tasks on an EventLoop that has already
    /// shut down" (and will upgrade to a forced crash in future NIO
    /// releases).
    func shutdown() async throws {
        let already = didShutdown.withLockedValue { state -> Bool in
            if state { return true }
            state = true
            return false
        }
        if already { return }
        try await httpClient.shutdown()
    }

    /// Send an HTTP request and return the response.
    ///
    /// Translates AHC errors → ``CloudHypervisor/Error/transport(_:)`` so
    /// callers see a uniform error type regardless of failure mode.
    func send(
        method: HTTPMethod,
        uri: String,
        body: Data?,
        headers: HTTPHeaders = [:]
    ) async throws -> HTTPResponse {
        // AHC handles the percent-encoding. nil only on a path that can't
        // be encoded — surface it the same way the public Client init does.
        guard let url = URL(httpURLWithSocketPath: socketPath, uri: uri) else {
            throw CloudHypervisor.Error.invalidSocketPath(socketPath)
        }

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method

        // Preserve all caller-supplied headers verbatim.
        for (name, value) in headers {
            request.headers.replaceOrAdd(name: name, value: value)
        }

        // `Connection: close` is preserved from the previous transport. CH
        // accepts both close and keep-alive, but close is the safer default
        // until we have explicit smoke coverage of long-lived per-VM
        // keep-alive behavior. Each request goes to a different per-VM UDS
        // anyway so there's nothing to pool.
        request.headers.replaceOrAdd(name: "Connection", value: "close")

        // Body framing. CH's HTTP parser rejects body-less PUTs unless the
        // request carries `Content-Length: 0` instead of falling back to
        // chunked transfer encoding.
        //
        // How AHC actually frames the request is subtle:
        // `RequestValidation.setTransportFraming` strips any manually-set
        // `Content-Length` and re-derives framing from the body's known
        // length. Assigning `.bytes(ByteBuffer())` (rather than leaving
        // body nil) sets `bodyLength == .known(0)`, which AHC then frames
        // as `Content-Length: 0` for PUT/POST per RFC 7230 §3.3.2. Leaving
        // body nil would surface as `bodyLength == .unknown`, and AHC may
        // emit chunked framing or no framing at all, which CH rejects.
        // The explicit `Content-Length: 0` header set below is documentation
        // of intent — AHC removes it before deriving framing — but the
        // wire shape is determined by the empty body assignment.
        //
        // Regression test: ClientTests.bodylessPUTSendsContentLengthZero.
        if let body, !body.isEmpty {
            if request.headers["Content-Type"].isEmpty {
                request.headers.add(name: "Content-Type", value: "application/json")
            }
            request.body = .bytes(ByteBuffer(bytes: body))
        } else {
            request.headers.replaceOrAdd(name: "Content-Length", value: "0")
            request.body = .bytes(ByteBuffer())
        }

        let deadline = NIODeadline.now() + requestTimeout
        logger.debug("HTTPOverUDSClient: \(method) \(uri) → \(socketPath)")

        do {
            let response = try await httpClient.execute(
                request,
                deadline: deadline,
                logger: logger
            )

            // 16 MiB is far larger than any CH response we expect — vm.info,
            // the largest, measures in low-KB even for many-disk VMs. The
            // cap exists so a wedged server can't OOM us.
            //
            // Use `readableBytesView` + the Sequence-based Data init rather
            // than `Data(buffer: ByteBuffer)`: the latter requires
            // `NIOFoundationCompat`, which the Linux musl build doesn't
            // pull in via Foundation by default.
            let bodyBuffer = try await response.body.collect(upTo: 1 << 24)
            let bodyData = Data(bodyBuffer.readableBytesView)

            logger.debug("HTTPOverUDSClient: \(method) \(uri) ← \(response.status.code)")
            return HTTPResponse(
                status: response.status,
                headers: response.headers,
                body: bodyData
            )
        } catch let error as CloudHypervisor.Error {
            throw error
        } catch {
            throw CloudHypervisor.Error.transport(error)
        }
    }

    deinit {
        // Fire the callback-based shutdown only when `shutdown()` wasn't
        // already called. The sync variant would deadlock if deinit
        // happened to run on one of the HTTPClient's own event loops
        // (commit fe1c95cf); the callback variant returns immediately at
        // the cost of any completion signal. If explicit shutdown
        // already ran, the HTTPClient is drained and a second call would
        // just return `alreadyShutdown` — but it can still try to
        // schedule the callback on the (now-dead) event loop, which is
        // exactly the failure mode this whole flag guards against.
        let already = didShutdown.withLockedValue { state -> Bool in
            if state { return true }
            state = true
            return false
        }
        guard !already else { return }
        httpClient.shutdown { _ in }
    }
}
