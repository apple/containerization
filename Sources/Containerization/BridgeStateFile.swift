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

/// On-disk record of state `BridgeManager.create()` modified, used by
/// `delete()` to restore the host. Stored at
/// `/run/containerization/bridge-<name>.state` (tmpfs — gone after host
/// reboot, which is fine because reboot already clears `ip_forward` and
/// the bridge link itself).
struct BridgeState: Codable, Equatable {
    /// Whether `create()` programmed NAT (iptables MASQUERADE/FORWARD +
    /// `ip_forward`). When `false`, the only thing `create()` did was bring
    /// the bridge up — `delete()` only needs to remove the link, not roll
    /// back NAT. State files predating this field are decoded as
    /// `natEnabled = true` for back-compat.
    let natEnabled: Bool

    /// Value of `/proc/sys/net/ipv4/ip_forward` read at the *first*
    /// `create()` call. Preserved across re-runs so `delete()` can restore
    /// the host's true original value. Only set when `natEnabled`.
    let prevIpForward: String?

    /// Egress interface that `create()` used in the iptables rules — passed
    /// explicitly by the caller, or auto-detected from `/proc/net/route`.
    /// Only set when `natEnabled`. Recorded for debug / observability and
    /// to scope the FORWARD rule's `-o` clause; rule removal is keyed off
    /// subnet, bridge name, and egress.
    let egressInterface: String?

    init(natEnabled: Bool, prevIpForward: String? = nil, egressInterface: String? = nil) {
        self.natEnabled = natEnabled
        self.prevIpForward = prevIpForward
        self.egressInterface = egressInterface
    }

    enum CodingKeys: String, CodingKey {
        case natEnabled
        case prevIpForward
        case egressInterface
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Default natEnabled to true when missing so files written by older
        // versions (which always programmed NAT) still describe themselves
        // accurately — delete() will roll back ip_forward / iptables.
        self.natEnabled = try container.decodeIfPresent(Bool.self, forKey: .natEnabled) ?? true
        self.prevIpForward = try container.decodeIfPresent(String.self, forKey: .prevIpForward)
        self.egressInterface = try container.decodeIfPresent(String.self, forKey: .egressInterface)
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> BridgeState {
        try JSONDecoder().decode(BridgeState.self, from: data)
    }
}
