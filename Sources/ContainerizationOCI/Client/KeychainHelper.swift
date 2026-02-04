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

#if os(macOS)
import Foundation
import ContainerizationOS

/// Helper type to lookup registry related values in the macOS keychain.
public struct KeychainHelper: Sendable {
    private let id: String
    public init(id: String) {
        self.id = id
    }

    /// Lookup authorization data for a given registry domain.
    public func lookup(domain: String) throws -> Authentication {
        let kq = KeychainQuery()

        do {
            guard let fetched = try kq.get(id: self.id, host: domain) else {
                throw Self.Error.keyNotFound
            }
            return BasicAuthentication(
                username: fetched.account,
                password: fetched.data
            )
        } catch let err as KeychainQuery.Error {
            switch err {
            case .keyNotPresent(_):
                throw Self.Error.keyNotFound
            default:
                throw Self.Error.queryError("query failure: \(String(describing: err))")
            }
        }
    }

    /// Delete authorization data for a given domain from the keychain.
    public func delete(domain: String) throws {
        let kq = KeychainQuery()
        try kq.delete(id: self.id, host: domain)
    }

    /// Save authorization data for a given domain to the keychain.
    public func save(domain: String, username: String, password: String) throws {
        let kq = KeychainQuery()
        try kq.save(id: self.id, host: domain, user: username, token: password)
    }

    /// Prompt for authorization data for a given domain to be saved to the keychain.
    /// This will cause the current terminal to enter a password prompt state where
    /// key strokes are hidden.
    public func credentialPrompt(domain: String) throws -> Authentication {
        let username = try userPrompt(domain: domain)
        let password = try passwordPrompt()
        return BasicAuthentication(username: username, password: password)
    }

    /// Prompts the current stdin for a username entry and then returns the value.
    public func userPrompt(domain: String) throws -> String {
        print("Provide registry username \(domain): ", terminator: "")
        guard let username = readLine() else {
            throw Self.Error.invalidInput
        }
        return username
    }

    /// Prompts the current stdin for a password entry and then returns the value.
    /// This will cause the current stdin (if it is a terminal) to hide keystrokes
    /// by disabling echo.
    public func passwordPrompt() throws -> String {
        print("Provide registry password: ", terminator: "")
        let console = try Terminal.current
        defer { console.tryReset() }
        try console.disableEcho()

        guard let password = readLine() else {
            throw Self.Error.invalidInput
        }
        return password
    }
}

extension KeychainHelper {
    /// `KeychainHelper` errors.
    public enum Error: Swift.Error {
        case keyNotFound
        case invalidInput
        case queryError(String)
    }
}
#endif
