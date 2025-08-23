//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
import Testing

@testable import ContainerizationOCI

struct BasicAuthenticationTests {

    @Test func basicTokenGeneration() async throws {
        let auth = BasicAuthentication(username: "user", password: "pass")
        let token = try await auth.token()

        let expectedCredentials = "user:pass"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenWithSpecialCharacters() async throws {
        let auth = BasicAuthentication(username: "user@domain.com", password: "p@ss!w0rd#123")
        let token = try await auth.token()

        let expectedCredentials = "user@domain.com:p@ss!w0rd#123"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenWithEmptyUsername() async throws {
        let auth = BasicAuthentication(username: "", password: "password")
        let token = try await auth.token()

        let expectedCredentials = ":password"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenWithEmptyPassword() async throws {
        let auth = BasicAuthentication(username: "username", password: "")
        let token = try await auth.token()

        let expectedCredentials = "username:"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenWithBothEmpty() async throws {
        let auth = BasicAuthentication(username: "", password: "")
        let token = try await auth.token()

        let expectedCredentials = ":"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenWithUnicodeCharacters() async throws {
        let auth = BasicAuthentication(username: "用户", password: "密码")
        let token = try await auth.token()

        let expectedCredentials = "用户:密码"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenWithLongCredentials() async throws {
        let longUsername = String(repeating: "u", count: 1000)
        let longPassword = String(repeating: "p", count: 1000)
        let auth = BasicAuthentication(username: longUsername, password: longPassword)
        let token = try await auth.token()

        let expectedCredentials = "\(longUsername):\(longPassword)"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenWithControlCharacters() async throws {
        let auth = BasicAuthentication(username: "user\t\n", password: "pass\r\n")
        let token = try await auth.token()

        let expectedCredentials = "user\t\n:pass\r\n"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenWithColonInUsername() async throws {
        let auth = BasicAuthentication(username: "user:name", password: "password")
        let token = try await auth.token()

        let expectedCredentials = "user:name:password"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenWithColonInPassword() async throws {
        let auth = BasicAuthentication(username: "username", password: "pass:word")
        let token = try await auth.token()

        let expectedCredentials = "username:pass:word"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenMultipleColons() async throws {
        let auth = BasicAuthentication(username: "user:name:here", password: "pass:word:here")
        let token = try await auth.token()

        let expectedCredentials = "user:name:here:pass:word:here"
        let expectedBase64 = expectedCredentials.data(using: .utf8)!.base64EncodedString()
        let expectedToken = "Basic \(expectedBase64)"

        #expect(token == expectedToken)
    }

    @Test func basicTokenBase64Verification() async throws {
        let testCases = [
            ("admin", "admin123"),
            ("user", ""),
            ("", "secret"),
            ("test@example.com", "P@ssw0rd!"),
            ("service-account", "very-long-password-with-special-chars-!@#$%^&*()"),
        ]

        for (username, password) in testCases {
            let auth = BasicAuthentication(username: username, password: password)
            let token = try await auth.token()

            #expect(token.hasPrefix("Basic "))

            let base64Part = String(token.dropFirst(6))
            guard let decodedData = Data(base64Encoded: base64Part),
                let decodedString = String(data: decodedData, encoding: .utf8)
            else {
                Issue.record("Failed to decode base64 token for \(username):\(password)")
                continue
            }

            let expectedCredentials = "\(username):\(password)"
            #expect(decodedString == expectedCredentials)
        }
    }
}
