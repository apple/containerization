//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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

public struct KeychainHelper: Sendable {
    private let id: String
    public init(id: String) {
        self.id = id
    }

    public func lookup(domain: String) throws -> Authentication {
        let kq = KeychainQuery()

        guard try kq.exists(id: self.id, host: domain) else {
            throw Self.Error.keyNotFound
        }
        guard let fetched = try kq.get(id: self.id, host: domain) else {
            throw Self.Error.keyNotFound
        }

        return BasicAuthentication(
            username: fetched.account,
            password: fetched.data
        )
    }

    public func delete(domain: String) throws {
        let kq = KeychainQuery()
        try kq.delete(id: self.id, host: domain)
    }

    public func save(domain: String, username: String, password: String) throws {
        let kq = KeychainQuery()
        try kq.save(id: self.id, host: domain, user: username, token: password)
    }

    public func credentialPrompt(domain: String) throws -> Authentication {
        let username = try userPrompt(domain: domain)
        let password = try passwordPrompt()
        return BasicAuthentication(username: username, password: password)
    }

    public func userPrompt(domain: String) throws -> String {
        print("Provide registry username \(domain): ", terminator: "")
        guard let username = readLine() else {
            throw Self.Error.invalidInput
        }
        return username
    }

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
    public enum Error: Swift.Error {
        case keyNotFound
        case invalidInput
    }
}
#endif
