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

/// DNS configuration for a container. The values will be used to
/// construct /etc/resolv.conf for a given container.
public struct DNS: Sendable {
    public static let defaultNameservers = ["1.1.1.1"]

    public var nameservers: [String]
    public var domain: String?
    public var searchDomains: [String]
    public var options: [String]

    public init(
        nameservers: [String] = defaultNameservers,
        domain: String? = nil,
        searchDomains: [String] = [],
        options: [String] = []
    ) {
        self.nameservers = nameservers
        self.domain = domain
        self.searchDomains = searchDomains
        self.options = options
    }
}

extension DNS {
    public var resolvConf: String {
        var text = ""

        if !nameservers.isEmpty {
            text += nameservers.map { "nameserver \($0)" }.joined(separator: "\n") + "\n"
        }

        if let domain {
            text += "domain \(domain)\n"
        }

        if !searchDomains.isEmpty {
            text += "search \(searchDomains.joined(separator: " "))\n"
        }

        if !options.isEmpty {
            text += "opts \(options.joined(separator: " "))\n"
        }

        return text
    }
}
