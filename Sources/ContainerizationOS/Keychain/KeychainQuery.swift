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

/// Holds the result of a query to the keychain.
public struct KeychainQueryResult {
    public var username: String
    public var password: String
    public var modifiedDate: Date
    public var createdDate: Date
}

/// Type that facilitates interacting with the macOS keychain.
public struct KeychainQuery {
    public init() {}

    /// Save a value to the keychain.
    /// - Parameters:
    ///   - securityDomain: The security domain used to fetch keychain entries.
    ///   - accessGroup: If present, the access group used to fetch keychain entries.
    ///   - hostname: The hostname for the authenticating server.
    ///   - username: The username to present to the server.
    ///   - password: The password to present to the server.
    /// - Throws: An error if the keychain query fails or returns unexpected data.
    public func save(
        securityDomain: String,
        accessGroup: String? = nil,
        hostname: String,
        username: String,
        password: String
    ) throws {
        if try exists(securityDomain: securityDomain, accessGroup: accessGroup, hostname: hostname) {
            try delete(securityDomain: securityDomain, accessGroup: accessGroup, hostname: hostname)
        }

        guard let passwordEncoded = password.data(using: String.Encoding.utf8) else {
            throw Self.Error.invalidPasswordConversion
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: securityDomain,
            kSecAttrServer as String: hostname,
            kSecAttrAccount as String: username,
            kSecValueData as String: passwordEncoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.Error.unhandledError(status: status) }
    }

    /// Delete a value from the keychain.
    /// - Parameters:
    ///   - securityDomain: The security domain used to fetch keychain entries.
    ///   - accessGroup: If present, the access group used to fetch keychain entries.
    ///   - hostname: The hostname for the authenticating server.
    /// - Throws: An error if the keychain query fails or returns unexpected data.
    public func delete(securityDomain: String, accessGroup: String? = nil, hostname: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: securityDomain,
            kSecAttrServer as String: hostname,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.Error.unhandledError(status: status)
        }
    }

    /// Retrieve a value from the keychain.
    /// - Parameters:
    ///   - securityDomain: The security domain used to fetch keychain entries.
    ///   - accessGroup: If present, the access group used to fetch keychain entries.
    ///   - hostname: The hostname for the authenticating server.
    /// - Returns: The keychain entry.
    /// - Throws: An error if the keychain query fails or returns unexpected data.
    public func get(securityDomain: String, accessGroup: String? = nil, hostname: String) throws -> KeychainQueryResult? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: securityDomain,
            kSecAttrServer as String: hostname,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let exists = try isQuerySuccessful(status)
        if !exists {
            return nil
        }

        guard let fetched = item as? [String: Any] else {
            throw Self.Error.unexpectedDataFetched
        }
        guard let data = fetched[kSecValueData as String] as? Data else {
            throw Self.Error.keyNotPresent(key: kSecValueData as String)
        }
        guard let password = String(data: data, encoding: String.Encoding.utf8) else {
            throw Self.Error.unexpectedDataFetched
        }
        guard let username = fetched[kSecAttrAccount as String] as? String else {
            throw Self.Error.keyNotPresent(key: kSecAttrAccount as String)
        }
        guard let modifiedDate = fetched[kSecAttrModificationDate as String] as? Date else {
            throw Self.Error.keyNotPresent(key: kSecAttrModificationDate as String)
        }
        guard let createdDate = fetched[kSecAttrCreationDate as String] as? Date else {
            throw Self.Error.keyNotPresent(key: kSecAttrCreationDate as String)
        }
        return KeychainQueryResult(
            username: username,
            password: password,
            modifiedDate: modifiedDate,
            createdDate: createdDate
        )
    }

    /// List all keychain entries for a domain.
    /// - Parameters:
    ///   - securityDomain: The security domain used to fetch keychain entries.
    ///   - accessGroup: If present, the access group used to fetch keychain entries.
    /// - Returns: An array of keychain metadata for each matching entry, or an empty array if none are found.
    /// - Throws: An error if the keychain query fails or returns unexpected data.
    public func list(securityDomain: String, accessGroup: String? = nil) throws -> [RegistryInfo] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: securityDomain,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let exists = try isQuerySuccessful(status)
        if !exists {
            return []
        }

        guard let fetched = item as? [[String: Any]] else {
            throw Self.Error.unexpectedDataFetched
        }

        return try fetched.map { registry in
            guard let hostname = registry[kSecAttrServer as String] as? String else {
                throw Self.Error.keyNotPresent(key: kSecAttrServer as String)
            }
            guard let username = registry[kSecAttrAccount as String] as? String else {
                throw Self.Error.keyNotPresent(key: kSecAttrAccount as String)
            }
            guard let modifiedDate = registry[kSecAttrModificationDate as String] as? Date else {
                throw Self.Error.keyNotPresent(key: kSecAttrModificationDate as String)
            }
            guard let createdDate = registry[kSecAttrCreationDate as String] as? Date else {
                throw Self.Error.keyNotPresent(key: kSecAttrCreationDate as String)
            }

            return RegistryInfo(
                hostname: hostname,
                username: username,
                modifiedDate: modifiedDate,
                createdDate: createdDate
            )
        }
    }

    /// Check if a value exists in the keychain.
    /// - Parameters:
    ///   - securityDomain: The security domain used to fetch keychain entries.
    ///   - accessGroup: If present, the access group used to fetch keychain entries.
    ///   - hostname: The hostname for the authenticating server.
    /// - Returns: `true` if the entry exists, `false` otherwise.
    /// - Throws: An error if the keychain query fails.
    public func exists(securityDomain: String, accessGroup: String? = nil, hostname: String) throws -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: securityDomain,
            kSecAttrServer as String: hostname,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return try isQuerySuccessful(status)
    }

    private func isQuerySuccessful(_ status: Int32) throws -> Bool {
        guard status != errSecItemNotFound else {
            return false
        }
        guard status == errSecSuccess else {
            throw Self.Error.unhandledError(status: status)
        }
        return true
    }
}

extension KeychainQuery {
    public enum Error: Swift.Error {
        case unhandledError(status: Int32)
        case unexpectedDataFetched
        case keyNotPresent(key: String)
        case invalidPasswordConversion
    }
}
#endif
