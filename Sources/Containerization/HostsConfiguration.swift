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

/// Static table lookups for a container. The values will be used to
/// construct /etc/hosts for a given container.
public struct Hosts: Sendable {
    /// Represents one entry in an /etc/hosts file.
    public struct Entry: Sendable {
        /// The IPV4 or IPV6 address in String form.
        public var ipAddress: String
        /// The hostname(s) for the entry.
        public var hostnames: [String]
        /// An optional comment to be placed to the right side of the entry.
        public var comment: String?

        public init(ipAddress: String, hostnames: [String], comment: String? = nil) {
            self.comment = comment
            self.hostnames = hostnames
            self.ipAddress = ipAddress
        }

        /// The information in the structure rendered to a String representation
        /// that matches the format /etc/hosts expects.
        public var rendered: String {
            var line = ipAddress
            if !hostnames.isEmpty {
                line += " " + hostnames.joined(separator: " ")
            }
            if let comment {
                line += " # \(comment) "
            }
            return line
        }

        public static func localHostIPV4(comment: String? = nil) -> Self {
            Self(
                ipAddress: "127.0.0.1",
                hostnames: ["localhost"],
                comment: comment
            )
        }

        public static func localHostIPV6(comment: String? = nil) -> Self {
            Self(
                ipAddress: "::1",
                hostnames: ["localhost", "ip6-localhost", "ip6-loopback"],
                comment: comment
            )
        }

        public static func ipv6LocalNet(comment: String? = nil) -> Self {
            Self(
                ipAddress: "fe00::",
                hostnames: ["ip6-localnet"],
                comment: comment
            )
        }

        public static func ipv6MulticastPrefix(comment: String? = nil) -> Self {
            Self(
                ipAddress: "ff00::",
                hostnames: ["ip6-mcastprefix"],
                comment: comment
            )
        }

        public static func ipv6AllNodes(comment: String? = nil) -> Self {
            Self(
                ipAddress: "ff02::1",
                hostnames: ["ip6-allnodes"],
                comment: comment
            )
        }

        public static func ipv6AllRouters(comment: String? = nil) -> Self {
            Self(
                ipAddress: "ff02::2",
                hostnames: ["ip6-allrouters"],
                comment: comment
            )
        }
    }

    /// The entries to be written to /etc/hosts.
    public var entries: [Entry]

    /// A comment to render at the top of the file.
    public var comment: String?

    public init(
        entries: [Entry],
        comment: String? = nil
    ) {
        self.entries = entries
        self.comment = comment
    }
}

extension Hosts {
    /// A default entry that can be used for convenience. It contains a IPV4
    /// and IPV6 localhost entry, as well as ipv6 localnet, ipv6 mcastprefix,
    /// ipv6 allnodes, and ipv6 allrouters.
    public static let `default` = Hosts(entries: [
        Entry.localHostIPV4(),
        Entry.localHostIPV6(),
        Entry.ipv6LocalNet(),
        Entry.ipv6MulticastPrefix(),
        Entry.ipv6AllNodes(),
        Entry.ipv6AllRouters(),
    ])

    /// Returns a string variant of the data that can be written to
    /// /etc/hosts directly.
    public var hostsFile: String {
        var lines: [String] = []

        if let comment {
            lines.append("# \(comment)")
        }

        for entry in entries {
            lines.append(entry.rendered)
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
