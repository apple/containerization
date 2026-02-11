//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOSSL

#if os(macOS)
import Network
#endif

/// Data used to control retry behavior for `RegistryClient`.
public struct RetryOptions: Sendable {
    /// The maximum number of retries to attempt before failing.
    public var maxRetries: Int
    /// The retry interval in nanoseconds.
    public var retryInterval: UInt64
    /// A provided closure to handle if a given HTTP response should be
    /// retried.
    public var shouldRetry: (@Sendable (HTTPClientResponse) -> Bool)?

    public init(maxRetries: Int, retryInterval: UInt64, shouldRetry: (@Sendable (HTTPClientResponse) -> Bool)? = nil) {
        self.maxRetries = maxRetries
        self.retryInterval = retryInterval
        self.shouldRetry = shouldRetry
    }
}

/// A client for interacting with OCI compliant container registries.
public final class RegistryClient: ContentClient {
    private static let defaultRetryOptions = RetryOptions(
        maxRetries: 3,
        retryInterval: 1_000_000_000,
        shouldRetry: ({ response in
            response.status.code >= 500
        })
    )

    let client: HTTPClient
    let proxyURL: URL?
    let base: URLComponents
    let clientID: String
    let authentication: Authentication?
    let retryOptions: RetryOptions?
    let bufferSize: Int

    public convenience init(
        reference: String,
        insecure: Bool = false,
        auth: Authentication? = nil,
        tlsConfiguration: TLSConfiguration? = nil,
        logger: Logger? = nil,
    ) throws {
        let ref = try Reference.parse(reference)
        guard let domain = ref.resolvedDomain else {
            throw ContainerizationError(.invalidArgument, message: "invalid domain for image reference \(reference)")
        }
        let scheme = insecure ? "http" : "https"
        let _url = "\(scheme)://\(domain)"
        guard let url = URL(string: _url) else {
            throw ContainerizationError(.invalidArgument, message: "cannot convert \(_url) to URL")
        }
        guard let host = url.host else {
            throw ContainerizationError(.invalidArgument, message: "invalid host \(domain)")
        }
        let port = url.port
        self.init(
            host: host,
            scheme: scheme,
            port: port,
            authentication: auth,
            retryOptions: Self.defaultRetryOptions,
            tlsConfiguration: tlsConfiguration,
        )
    }

    public init(
        host: String,
        scheme: String? = "https",
        port: Int? = nil,
        authentication: Authentication? = nil,
        clientID: String? = nil,
        retryOptions: RetryOptions? = nil,
        bufferSize: Int = Int(4.mib()),
        tlsConfiguration: TLSConfiguration? = nil,
        logger: Logger? = nil,
    ) {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port

        self.base = components
        self.clientID = clientID ?? "containerization-registry-client"
        self.authentication = authentication
        self.retryOptions = retryOptions
        self.bufferSize = bufferSize
        var httpConfiguration = HTTPClient.Configuration()

        // proxy configuration assumes all client requests will go to `base` URL
        self.proxyURL = ProxyUtils.proxyFromEnvironment(scheme: scheme, host: host)
        if let proxyURL = self.proxyURL, let proxyHost = proxyURL.host {
            let proxyPort = proxyURL.port ?? (proxyURL.scheme == "https" ? 443 : 80)
            httpConfiguration.proxy = HTTPClient.Configuration.Proxy.server(host: proxyHost, port: proxyPort)
        }
        if tlsConfiguration != nil {
            httpConfiguration.tlsConfiguration = tlsConfiguration
        }

        if let logger {
            self.client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration, backgroundActivityLogger: logger)
        } else {
            self.client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration)
        }
    }

    deinit {
        _ = client.shutdown()
    }

    func host() -> String {
        base.host ?? ""
    }

    internal func request<T>(
        components: URLComponents,
        method: HTTPMethod = .GET,
        bodyClosure: () throws -> HTTPClientRequest.Body? = { nil },
        headers: [(String, String)]? = nil,
        closure: (HTTPClientResponse) async throws -> T
    ) async throws -> T {
        guard let path = components.url?.absoluteString else {
            throw ContainerizationError(.invalidArgument, message: "invalid url \(components.path)")
        }

        var request = HTTPClientRequest(url: path)
        request.method = method

        var currentToken: TokenResponse?
        let token: String? = try await {
            if let basicAuth = authentication {
                return try await basicAuth.token()
            }
            return nil
        }()

        if let token {
            request.headers.add(name: "Authorization", value: "\(token)")
        }

        // Add any arbitrary headers
        headers?.forEach { (k, v) in request.headers.add(name: k, value: v) }
        var retryCount = 0
        var response: HTTPClientResponse?
        while true {
            request.body = try bodyClosure()
            do {
                let _response = try await client.execute(request, deadline: .distantFuture)
                response = _response
                if _response.status == .unauthorized || _response.status == .forbidden {
                    let authHeader = _response.headers[TokenRequest.authenticateHeaderName]
                    let tokenRequest: TokenRequest
                    do {
                        tokenRequest = try self.createTokenRequest(parsing: authHeader)
                    } catch {
                        // The server did not tell us how to authenticate our requests,
                        // Or we do not support scheme the server is requesting for.
                        // Throw the 401/403 to the caller, and let them decide how to proceed.
                        throw RegistryClient.Error.invalidStatus(url: path, _response.status, reason: String(describing: error))
                    }
                    if let ct = currentToken, ct.isValid(scope: tokenRequest.scope) {
                        break
                    }

                    do {
                        let _currentToken = try await fetchToken(request: tokenRequest)
                        guard let token = _currentToken.getToken() else {
                            throw ContainerizationError(.internalError, message: "failed to fetch Bearer token")
                        }
                        currentToken = _currentToken
                        request.headers.replaceOrAdd(name: "Authorization", value: token)
                        retryCount += 1
                    } catch let err as RegistryClient.Error {
                        guard case .invalidStatus(_, let status, _) = err else {
                            throw err
                        }
                        if status == .unauthorized || status == .forbidden {
                            throw RegistryClient.Error.invalidStatus(url: path, _response.status, reason: "access denied or wrong credentials")
                        }

                        throw err
                    }

                    continue
                }
                guard let retryOptions = self.retryOptions else {
                    break
                }
                guard retryCount < retryOptions.maxRetries else {
                    break
                }
                guard let shouldRetry = retryOptions.shouldRetry, shouldRetry(_response) else {
                    break
                }
                retryCount += 1
                try await Task.sleep(nanoseconds: retryOptions.retryInterval)
                continue
            } catch let err as RegistryClient.Error {
                throw err
            } catch {
                #if os(macOS)
                if let err = error as? NWError {
                    if err.errorCode == kDNSServiceErr_NoSuchRecord {
                        let message: String
                        if let proxyURL = self.proxyURL, let proxyHost = proxyURL.host {
                            message = "failed to resolve either repository hostname \(host()) or proxy hostname \(proxyHost)"
                        } else {
                            message = "failed to resolve either repository hostname \(host())"
                        }
                        throw ContainerizationError(.internalError, message: message)
                    }
                }
                #endif
                guard let retryOptions = self.retryOptions, retryCount < retryOptions.maxRetries else {
                    throw error
                }
                retryCount += 1
                try await Task.sleep(nanoseconds: retryOptions.retryInterval)
            }
        }
        guard let response else {
            throw ContainerizationError(.internalError, message: "invalid response")
        }
        return try await closure(response)
    }

    internal func requestData(
        components: URLComponents,
        headers: [(String, String)]? = nil
    ) async throws -> Data {
        let bytes: ByteBuffer = try await requestBuffer(components: components, headers: headers)
        return Data(buffer: bytes)
    }

    internal func requestBuffer(
        components: URLComponents,
        headers: [(String, String)]? = nil
    ) async throws -> ByteBuffer {
        try await request(components: components, method: .GET, headers: headers) { response in
            guard response.status == .ok else {
                let url = components.url?.absoluteString ?? "unknown"
                let reason = await ErrorResponse.fromResponseBody(response.body)?.jsonString
                throw Error.invalidStatus(url: url, response.status, reason: reason)
            }

            return try await response.body.collect(upTo: self.bufferSize)
        }
    }

    internal func requestJSON<T: Decodable>(
        components: URLComponents,
        headers: [(String, String)]? = nil
    ) async throws -> T {
        let buffer = try await self.requestBuffer(components: components, headers: headers)
        return try JSONDecoder().decode(T.self, from: buffer)
    }

    /// A minimal endpoint, mounted at /v2/ will provide version support information based on its response statuses.
    /// See https://distribution.github.io/distribution/spec/api/#api-version-check
    public func ping() async throws {
        var components = base
        components.path = "/v2/"

        try await request(components: components) { response in
            guard response.status == .ok else {
                let url = components.url?.absoluteString ?? "unknown"
                let reason = await ErrorResponse.fromResponseBody(response.body)?.jsonString
                throw Error.invalidStatus(url: url, response.status, reason: reason)
            }
        }
    }
}
