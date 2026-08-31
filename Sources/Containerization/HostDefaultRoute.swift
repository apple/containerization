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

/// Reads the host's default IPv4 egress interface from `/proc/net/route`.
///
/// `/proc/net/route` columns (tab-separated):
///
///     Iface  Destination  Gateway  Flags  RefCnt  Use  Metric  Mask  MTU  Window  IRTT
///
/// Numeric fields are hex with bytes in network order (so `0102A8C0` is
/// `192.168.2.1`). Pure-string parsing keeps this cross-platform-testable
/// even though `/proc/net/route` itself only exists on Linux.
enum HostDefaultRoute {
    /// `RTF_GATEWAY` from `<linux/route.h>`. Set on rows representing a gateway route.
    private static let RTF_GATEWAY: UInt32 = 0x0002

    /// Parse the contents of `/proc/net/route` and return the iface for the
    /// default route (destination 0.0.0.0 with `RTF_GATEWAY`). When multiple
    /// default routes exist, the one with the lowest metric wins.
    static func parseEgress(procNetRoute contents: String) -> String? {
        var best: (iface: String, metric: UInt64)?
        for (i, line) in contents.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if i == 0 { continue }  // header
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 11 else { continue }
            let iface = String(cols[0])
            let destination = cols[1]
            let flagsHex = cols[3]
            let metricStr = cols[6]

            guard destination == "00000000" else { continue }
            guard let flags = UInt32(flagsHex, radix: 16),
                flags & RTF_GATEWAY != 0
            else { continue }
            let metric = UInt64(metricStr) ?? UInt64.max
            if let current = best, metric >= current.metric {
                continue
            }
            best = (iface, metric)
        }
        return best?.iface
    }

    /// Read `/proc/net/route` and return the default-route iface, or nil if
    /// the file is missing or no default route exists.
    static func currentEgress() -> String? {
        guard let contents = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) else {
            return nil
        }
        return parseEgress(procNetRoute: contents)
    }
}
