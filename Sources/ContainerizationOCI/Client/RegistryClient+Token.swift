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
import Foundation

struct TokenRequest {
    public static let authenticateHeaderName = "WWW-Authenticate"

    /// The credentials that will be used in the authentication header when fetching the token.
    let authentication: Authentication?
    /// The realm against which the token should be requested.
    let realm: String
    /// The name of the service which hosts the resource.
    let service: String
    /// Whether to return a refresh token along with the bearer token.
    let offlineToken: Bool
    /// String identifying the client.
    let clientId: String
    /// The resource in question, formatted as one of the space-delimited entries from the scope parameters from the WWW-Authenticate header shown above.
    let scope: String?

    init(
        realm: String,
        service: String,
        clientId: String,
        scope: String?,
        offlineToken: Bool = false,
        authentication: Authentication? = nil
    ) {
        self.realm = realm
        self.service = service
        self.offlineToken = offlineToken
        self.clientId = clientId
        self.scope = scope
        self.authentication = authentication
    }
}

struct TokenResponse: Codable, Hashable {
    /// An opaque Bearer token that clients should supply to subsequent requests in the Authorization header.
    let token: String?
    /// For compatibility with OAuth 2.0, we will also accept token under the name access_token.
    /// At least one of these fields must be specified, but both may also appear (for compatibility with older clients).
    /// When both are specified, they should be equivalent; if they differ the client's choice is undefined.
    let accessToken: String?
    ///  The duration in seconds since the token was issued that it will remain valid.
    ///  When omitted, this defaults to 60 seconds.
    let expiresIn: UInt?
    /// The RFC3339-serialized UTC standard time at which a given token was issued.
    /// If issued_at is omitted, the expiration is from when the token exchange completed.
    let issuedAt: String?
    /// Token which can be used to get additional access tokens for the same subject with different scopes.
    /// This token should be kept secure by the client and only sent to the authorization server which issues bearer tokens.
    /// This field will only be set when `offline_token=true` is provided in the request.
    let refreshToken: String?

    var scope: String?

    private enum CodingKeys: String, CodingKey {
        case token = "token"
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case issuedAt = "issued_at"
        case refreshToken = "refresh_token"
    }

    func getToken() -> String? {
        if let t = token ?? accessToken {
            return "Bearer \(t)"
        }
        return nil
    }

    func isValid(scope: String?) -> Bool {
        guard let issuedAt else {
            return false
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let issued = isoFormatter.date(from: issuedAt) else {
            return false
        }
        let expiresIn = expiresIn ?? 0
        let now = Date()
        let elapsed = now.timeIntervalSince(issued)
        guard elapsed < Double(expiresIn) else {
            return false
        }
        if let requiredScope = scope {
            return requiredScope == self.scope
        }
        return false
    }
}

struct AuthenticateChallenge: Equatable {
    let type: String
    let realm: String?
    let service: String?
    let scope: String?
    let error: String?

    init(type: String, realm: String?, service: String?, scope: String?, error: String?) {
        self.type = type
        self.realm = realm
        self.service = service
        self.scope = scope
        self.error = error
    }

    init(type: String, values: [String: String]) {
        self.type = type
        self.realm = values["realm"]
        self.service = values["service"]
        self.scope = values["scope"]
        self.error = values["error"]
    }
}

extension RegistryClient {
    /// Fetch an auto token for all subsequent HTTP requests
    /// See https://docs.docker.com/registry/spec/auth/token/
    internal func fetchToken(request: TokenRequest) async throws -> TokenResponse {
        guard var components = URLComponents(string: request.realm) else {
            throw ContainerizationError(.invalidArgument, message: "cannot create URL from \(request.realm)")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: request.clientId),
            URLQueryItem(name: "service", value: request.service),
        ]
        var scope = ""
        if let reqScope = request.scope {
            scope = reqScope
            components.queryItems?.append(URLQueryItem(name: "scope", value: reqScope))
        }

        if request.offlineToken {
            components.queryItems?.append(URLQueryItem(name: "offline_token", value: "true"))
        }
        var response: TokenResponse = try await requestJSON(components: components, headers: [])
        response.scope = scope
        return response
    }

    internal func createTokenRequest(parsing authenticateHeaders: [String]) throws -> TokenRequest {
        let parsedHeaders = Self.parseWWWAuthenticateHeaders(headers: authenticateHeaders)
        let bearerChallenge = parsedHeaders.first { $0.type == "Bearer" }
        guard let bearerChallenge else {
            throw ContainerizationError(.invalidArgument, message: "missing Bearer challenge in \(TokenRequest.authenticateHeaderName) header")
        }
        guard let realm = bearerChallenge.realm else {
            throw ContainerizationError(.invalidArgument, message: "cannot parse realm from \(TokenRequest.authenticateHeaderName) header")
        }
        guard let service = bearerChallenge.service else {
            throw ContainerizationError(.invalidArgument, message: "cannot parse service from \(TokenRequest.authenticateHeaderName) header")
        }
        let scope = bearerChallenge.scope
        let tokenRequest = TokenRequest(realm: realm, service: service, clientId: self.clientID, scope: scope, authentication: self.authentication)
        return tokenRequest
    }

    internal static func parseWWWAuthenticateHeaders(headers: [String]) -> [AuthenticateChallenge] {
        var parsed: [String: [String: String]] = [:]
        for challenge in headers {
            let trimmedChallenge = challenge.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmedChallenge.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            guard let scheme = parts.first else {
                continue
            }
            var params: [String: String] = [:]
            let header = String(parts[1])
            let pattern = #"(\w+)="([^"]+)"#
            let regex = try! NSRegularExpression(pattern: pattern, options: [])
            let matches = regex.matches(in: header, options: [], range: NSRange(header.startIndex..., in: header))
            for match in matches {
                if let keyRange = Range(match.range(at: 1), in: header),
                    let valueRange = Range(match.range(at: 2), in: header)
                {
                    let key = String(header[keyRange])
                    let value = String(header[valueRange])
                    params[key] = value
                }
            }
            parsed[String(scheme)] = params
        }
        var parsedChallenges: [AuthenticateChallenge] = []
        for (type, values) in parsed {
            parsedChallenges.append(.init(type: type, values: values))
        }
        return parsedChallenges
    }
}
