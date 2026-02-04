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

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

extension Application {
    struct Login: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "Login to a registry"
        )

        @OptionGroup() var application: Application

        @Option(name: .shortAndLong, help: "Username")
        var username: String = ""

        @Flag(help: "Take the password from stdin")
        var passwordStdin: Bool = false

        @Argument(help: "Registry server name")
        var server: String

        @Flag(help: "Use plain text http to authenticate") var http: Bool = false

        func run() async throws {
            var username = self.username
            var password = ""
            if passwordStdin {
                if username == "" {
                    throw ContainerizationError(.invalidArgument, message: "must provide --username with --password-stdin")
                }
                guard let passwordData = try FileHandle.standardInput.readToEnd() else {
                    throw ContainerizationError(.invalidArgument, message: "failed to read password from stdin")
                }
                password = String(decoding: passwordData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let keychain = KeychainHelper(id: Application.keychainID)
            if username == "" {
                username = try keychain.userPrompt(domain: server)
            }
            if password == "" {
                password = try keychain.passwordPrompt()
                print()
            }

            let server = Reference.resolveDomain(domain: self.server)
            let scheme = http ? "http" : "https"
            let client = RegistryClient(
                host: server,
                scheme: scheme,
                authentication: BasicAuthentication(username: username, password: password),
                retryOptions: .init(
                    maxRetries: 10,
                    retryInterval: 300_000_000,
                    shouldRetry: ({ response in
                        response.status.code >= 500
                    })
                ),
                tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration(),
            )
            try await client.ping()
            try keychain.save(domain: server, username: username, password: password)
            print("Login succeeded")
        }
    }
}
