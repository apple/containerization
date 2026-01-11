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

@testable import Containerization

struct HostsTests {

    @Test func hostsEntryRenderedWithAllFields() {
        let entry = Hosts.Entry(
            ipAddress: "192.168.1.100",
            hostnames: ["myserver", "server.local"],
            comment: "My local server"
        )

        let expected = "192.168.1.100 myserver server.local # My local server "
        #expect(entry.rendered == expected)
    }

    @Test func hostsEntryRenderedWithoutComment() {
        let entry = Hosts.Entry(
            ipAddress: "10.0.0.1",
            hostnames: ["gateway"]
        )

        let expected = "10.0.0.1 gateway"
        #expect(entry.rendered == expected)
    }

    @Test func hostsEntryRenderedWithEmptyHostnames() {
        let entry = Hosts.Entry(
            ipAddress: "172.16.0.1",
            hostnames: [],
            comment: "Empty hostnames"
        )

        let expected = "172.16.0.1 # Empty hostnames "
        #expect(entry.rendered == expected)
    }

    @Test func hostsFileWithCommentAndEntries() {
        let hosts = Hosts(
            entries: [
                Hosts.Entry(ipAddress: "127.0.0.1", hostnames: ["localhost"]),
                Hosts.Entry(ipAddress: "192.168.1.10", hostnames: ["server"], comment: "Main server"),
            ],
            comment: "Generated hosts file"
        )

        let expected = "# Generated hosts file\n127.0.0.1 localhost\n192.168.1.10 server # Main server \n"
        #expect(hosts.hostsFile == expected)
    }
}
