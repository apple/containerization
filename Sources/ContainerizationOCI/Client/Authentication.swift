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

import Foundation

/// Abstraction for returning a token needed for logging into an OCI compliant registry.
public protocol Authentication: Sendable {
    func token() async throws -> String
}

/// Type representing authentication information for client to access the registry.
public struct BasicAuthentication: Authentication {
    /// The username for the authentication.
    let username: String
    /// The password or identity token for the user.
    let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Get a token using the provided username and password. This will be a
    /// base64 encoded string of the username and password delimited by a colon.
    public func token() async throws -> String {
        let credentials = "\(username):\(password)"
        if let authenticationData = credentials.data(using: .utf8)?.base64EncodedString() {
            return "Basic \(authenticationData)"
        }
        throw Error.invalidCredentials
    }

    /// `BasicAuthentication` errors.
    public enum Error: Swift.Error {
        case invalidCredentials
    }
}
