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
import Testing

@testable import ContainerizationOCI

struct OCISpecTests {
    @Test func minimalSpecDecode() throws {
        let version = "1.2.3"
        let minSpec =
            """
                {
                    "ociVersion": "\(version)"
                }
            """

        guard let data = minSpec.data(using: .utf8) else {
            Issue.record("test spec is not valid: \(minSpec)")
            return
        }

        let decodedSpec = try JSONDecoder().decode(ContainerizationOCI.Spec.self, from: data)
        #expect(decodedSpec.version == version)
        #expect(decodedSpec.hooks == nil)
        #expect(decodedSpec.process == nil)
        #expect(decodedSpec.hostname == "")
        #expect(decodedSpec.domainname == "")
        #expect(decodedSpec.mounts.isEmpty)
        #expect(decodedSpec.annotations == nil)
        #expect(decodedSpec.root == nil)
        #expect(decodedSpec.linux == nil)
    }

    @Test func minimalProcessSpecDecode() throws {
        let cwd = "/test"
        let minProcessSpec =
            """
                {
                    "cwd": "\(cwd)",
                    "user": {
                        "uid": 10,
                        "gid": 11
                    }
                }
            """

        guard let data = minProcessSpec.data(using: .utf8) else {
            Issue.record("test process spec is not valid: \(minProcessSpec)")
            return
        }

        let decodedSpec = try JSONDecoder().decode(ContainerizationOCI.Process.self, from: data)
        #expect(decodedSpec.cwd == cwd)
        #expect(decodedSpec.env.isEmpty)
        #expect(decodedSpec.consoleSize == nil)
        #expect(decodedSpec.selinuxLabel == "")
        #expect(decodedSpec.noNewPrivileges == false)
        #expect(decodedSpec.commandLine == "")
        #expect(decodedSpec.oomScoreAdj == nil)
        #expect(decodedSpec.capabilities == nil)
        #expect(decodedSpec.apparmorProfile == "")
        #expect(decodedSpec.user.uid == 10)
        #expect(decodedSpec.user.gid == 11)
        #expect(decodedSpec.rlimits.isEmpty)
        #expect(decodedSpec.terminal == false)
    }

    @Test func minimalUserSpecDecode() throws {
        let minUserSpec =
            """
                {
                    "uid": 10,
                    "gid": 11
                }
            """

        guard let data = minUserSpec.data(using: .utf8) else {
            Issue.record("test user spec is not valid: \(minUserSpec)")
            return
        }

        let decodedSpec = try JSONDecoder().decode(ContainerizationOCI.User.self, from: data)
        #expect(decodedSpec.uid == 10)
        #expect(decodedSpec.gid == 11)
        #expect(decodedSpec.umask == nil)
        #expect(decodedSpec.additionalGids.isEmpty)
        #expect(decodedSpec.username == "")
    }

    @Test func minimalRootSpecDecode() throws {
        let path = "/testpath"
        let minRootSpec =
            """
                {
                    "path": "\(path)"
                }
            """

        guard let data = minRootSpec.data(using: .utf8) else {
            Issue.record("test root spec is not valid: \(minRootSpec)")
            return
        }

        let decodedSpec = try JSONDecoder().decode(ContainerizationOCI.Root.self, from: data)
        #expect(decodedSpec.path == path)
        #expect(decodedSpec.readonly == false)
    }

    @Test func minimalMountSpecDecode() throws {
        let destination = "/testdest"
        let minMountSpec =
            """
                {
                    "destination": "\(destination)"
                }
            """

        guard let data = minMountSpec.data(using: .utf8) else {
            Issue.record("test mount spec is not valid: \(minMountSpec)")
            return
        }

        let decodedSpec = try JSONDecoder().decode(ContainerizationOCI.Mount.self, from: data)
        #expect(decodedSpec.type == "")
        #expect(decodedSpec.source == "")
        #expect(decodedSpec.destination == destination)
        #expect(decodedSpec.options.isEmpty)
        #expect(decodedSpec.uidMappings == nil)
        #expect(decodedSpec.gidMappings == nil)
    }

    @Test func minimalCapabilitiesDecode() throws {
        let minCapabilitiesSpec =
            """
                {
                    "ociVersion": "1.1.0",
                    "capabilities": {
                        "permitted": [
                            "CAP_SYS_ADMIN"
                        ]
                    },
                    "linux": {}
                }
            """

        guard let data = minCapabilitiesSpec.data(using: .utf8) else {
            Issue.record("test capabilities spec is not valid: \(minCapabilitiesSpec)")
            return
        }

        let _ = try JSONDecoder().decode(ContainerizationOCI.Spec.self, from: data)
    }
}
