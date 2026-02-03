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
    private let securityDomain: String
    public init(securityDomain: String) {
        self.securityDomain = securityDomain
    }

    /// Lookup authorization data for a given registry hostname.
    public func lookup(hostname: String) throws -> Authentication {
        let kq = KeychainQuery()

        do {
            guard let fetched = try kq.get(securityDomain: self.securityDomain, hostname: hostname) else {
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

    /// Lists all registry entries for this security domain.
    /// - Returns: An array of registry metadata for each matching entry, or an empty array if none are found.
    /// - Throws: An error if the keychain query fails.
    public func list() throws -> [RegistryInfo] {
        let kq = KeychainQuery()
        return try kq.list(securityDomain: self.securityDomain)
    }

    /// Delete authorization data for a given hostname from the keychain.
    public func delete(hostname: String) throws {
        let kq = KeychainQuery()
        try kq.delete(securityDomain: self.securityDomain, hostname: hostname)
    }

    /// Save authorization data for a given hostname to the keychain.
    public func save(hostname: String, username: String, password: String) throws {
        let kq = KeychainQuery()
        try kq.save(securityDomain: self.securityDomain, hostname: hostname, user: username, token: password)
    }

    /// Prompt for authorization data for a given hostname to be saved to the keychain.
    /// This will cause the current terminal to enter a password prompt state where
    /// key strokes are hidden.
    public func credentialPrompt(hostname: String) throws -> Authentication {
        let username = try userPrompt(hostname: hostname)
        let password = try passwordPrompt()
        return BasicAuthentication(username: username, password: password)
    }

    /// Prompts the current stdin for a username entry and then returns the value.
    public func userPrompt(hostname: String) throws -> String {
        print("Provide registry username \(hostname): ", terminator: "")
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
