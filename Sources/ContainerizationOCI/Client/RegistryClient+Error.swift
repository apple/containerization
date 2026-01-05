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
import Foundation
import NIOHTTP1

extension RegistryClient {
    /// `RegistryClient` errors.
    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidStatus(url: String, HTTPResponseStatus, reason: String? = nil)

        /// Description of the errors.
        public var description: String {
            switch self {
            case .invalidStatus(let u, let response, let reason):
                return "HTTP request to \(u) failed with response: \(response.description). Reason: \(reason ?? "Unknown")"
            }
        }
    }

    /// The container registry typically returns actionable failure reasons in the response body
    /// of the failing HTTP Request. This type models the structure of the error message.
    /// Reference: https://distribution.github.io/distribution/spec/api/#errors
    internal struct ErrorResponse: Codable {
        let errors: [RemoteError]

        internal struct RemoteError: Codable {
            let code: String
            let message: String
            let detail: String?
        }

        internal static func fromResponseBody(_ body: HTTPClientResponse.Body) async -> ErrorResponse? {
            guard var buffer = try? await body.collect(upTo: Int(1.mib())) else {
                return nil
            }
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
                return nil
            }
            let data = Data(bytes)
            guard let jsonError = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
                return nil
            }
            return jsonError
        }

        public var jsonString: String {
            let data = try? JSONEncoder().encode(self)
            guard let data else {
                return "{}"
            }
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }
}
