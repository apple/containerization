//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import Containerization

@Suite
struct UnixSocketRelayTests {
    @Test
    func outOfRelayAppliesRequestedHostSocketPermissions() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "containerization-relay-\(UUID())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("service.sock")
        let configuration = UnixSocketConfiguration(
            source: URL(fileURLWithPath: "/run/service.sock"),
            destination: socketPath,
            permissions: .init(rawValue: 0o600),
            direction: .outOf
        )

        let listener = try UnixSocketRelay.makeHostListener(configuration)
        defer { try? listener.close() }
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: socketPath.path)[
                .posixPermissions
            ] as? NSNumber
        )
        #expect(permissions.uint16Value == 0o600)
    }
}
