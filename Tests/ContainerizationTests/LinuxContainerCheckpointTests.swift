//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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

@testable import Containerization

struct LinuxContainerCheckpointTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-\(UUID().uuidString).json")
    }

    @Test func roundTripsThroughDisk() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let checkpoint = LinuxContainer.Checkpoint(id: "my-container")
        try checkpoint.save(to: url)

        let loaded = try LinuxContainer.Checkpoint.load(from: url)
        #expect(loaded == checkpoint)
        #expect(loaded.id == "my-container")
        #expect(loaded.version == LinuxContainer.Checkpoint.currentVersion)
    }

    @Test func loadFailsForMissingFile() {
        #expect(throws: (any Error).self) {
            try LinuxContainer.Checkpoint.load(from: temporaryFile())
        }
    }

    @Test func loadFailsForMalformedManifest() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        #expect(throws: (any Error).self) {
            try LinuxContainer.Checkpoint.load(from: url)
        }
    }

    @Test func manifestUsesStableKeys() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try LinuxContainer.Checkpoint(id: "abc").save(to: url)

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["id"] as? String == "abc")
        #expect(object?["version"] as? Int == LinuxContainer.Checkpoint.currentVersion)
    }
}
