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

#if os(Linux)
import ContainerizationError
import ContainerizationExtras
import ContainerizationNetlink
import Foundation
import Logging

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Linux-only host plumbing for a container bridge network.
///
/// `create()` is idempotent: it brings the bridge to a known state (created
/// if absent, configured if already present), records what it changed in
/// `/run/containerization/bridge-<name>.state`, and `delete()` reverses
/// only what was recorded.
///
/// **NAT is opt-in.** With the default (`enableNAT: false`) `create()` only
/// brings up the bridge link and assigns the gateway IP — it does NOT touch
/// `ip_forward`, does NOT program iptables, and does NOT pick an egress
/// interface. Containers attached to the bridge can talk to each other and
/// to the host, but not to the outside world. Pass `enableNAT: true` to
/// also enable IPv4 forwarding and program a scoped MASQUERADE/FORWARD
/// pair (`-i <bridge> -o <egress>`); the bridge becomes a NAT exit and the
/// host now routes guest traffic.
///
/// Concurrent `create()`/`delete()` calls (e.g. from two `cctl run`
/// processes) serialize via `flock(LOCK_EX)` on
/// `/run/containerization/bridge-<name>.lock`.
///
/// Requires root (or `CAP_NET_ADMIN` plus, when NAT is enabled, the ability
/// to write `/proc/sys/...` and invoke `iptables`).
public struct BridgeManager: Sendable {
    public let name: String
    public let subnet: CIDRv4
    public let gateway: IPv4Address
    public let mtu: UInt32
    public let egressInterface: String?
    public let enableNAT: Bool
    private let log: Logger

    /// - Parameters:
    ///   - name: bridge interface name (e.g. `cz0`).
    ///   - subnet: subnet to assign on the bridge.
    ///   - gateway: host-side IP on the bridge. Defaults to `subnet.gateway`
    ///     (= `subnet.lower + 1`).
    ///   - mtu: bridge MTU. Default 1500.
    ///   - egressInterface: explicit egress iface for MASQUERADE. nil =
    ///     auto-detect via `/proc/net/route` at `create()` time. Only used
    ///     when `enableNAT` is true.
    ///   - enableNAT: when true, program iptables MASQUERADE+FORWARD and
    ///     enable `net.ipv4.ip_forward`. Default false — the bridge is
    ///     created without external connectivity, leaving host firewall
    ///     policy untouched.
    ///   - logger: optional logger. Defaults to a `bridge`-labeled logger.
    public init(
        name: String,
        subnet: CIDRv4,
        gateway: IPv4Address? = nil,
        mtu: UInt32 = 1500,
        egressInterface: String? = nil,
        enableNAT: Bool = false,
        logger: Logger? = nil
    ) {
        self.name = Self.validateInterfaceName(name)
        self.subnet = subnet
        self.gateway = gateway ?? subnet.gateway
        self.mtu = mtu
        self.egressInterface = egressInterface.map(Self.validateInterfaceName)
        self.enableNAT = enableNAT
        self.log = logger ?? Logger(label: "com.apple.containerization.bridge")
    }

    /// Reject obviously-bogus interface names before they hit netlink or
    /// `iptables`. This is a defense-in-depth check; the kernel and
    /// `iptables` themselves will also reject pathological inputs, but doing
    /// it here surfaces the error in a callable Swift API rather than as a
    /// netlink rc or iptables exit. Asserts (rather than throws) — these
    /// constraints are static, so a violation is a programming error.
    private static func validateInterfaceName(_ name: String) -> String {
        // IFNAMSIZ on Linux is 16 (15 usable + NUL). iptables itself caps
        // at 15. Names with `/`, whitespace, or NUL are kernel-rejected.
        precondition(!name.isEmpty, "interface name must be non-empty")
        precondition(name.utf8.count <= 15, "interface name '\(name)' exceeds IFNAMSIZ-1 (15)")
        precondition(
            !name.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\0" || $0 == ":" }),
            "interface name '\(name)' contains invalid characters"
        )
        return name
    }

    /// Idempotent create.
    public func create() throws {
        try Self.ensureStateDirectory()
        let lock = try FileLock(path: Self.lockPath(for: name))
        try lock.withExclusive {
            try createLocked()
        }
    }

    /// Idempotent delete. No-op when the bridge does not exist.
    public func delete() throws {
        try Self.ensureStateDirectory()
        let lock = try FileLock(path: Self.lockPath(for: name))
        try lock.withExclusive {
            try deleteLocked()
        }
    }

    private func createLocked() throws {
        let session = NetlinkSession(socket: try DefaultNetlinkSocket(), log: log)
        let stateURL = URL(fileURLWithPath: Self.statePath(for: name))

        // Preserve `prevIpForward` across re-runs: a second NAT-enabled
        // create() call would otherwise read the value the FIRST run left
        // behind ("1") and clobber the original prior state, so delete()
        // couldn't restore.
        let priorState: BridgeState? = (try? Data(contentsOf: stateURL))
            .flatMap { try? BridgeState.decode($0) }

        // 1. Bridge link.
        do {
            try session.linkAddBridge(name: name)
            log.info("created bridge \(name)")
        } catch {
            // EEXIST is fine; treat any error as "maybe it exists" and probe.
            // `linkGet` throws ENODEV when the iface is absent (rather than
            // returning an empty array), so coalesce both shapes to "absent".
            let existing = (try? session.linkGet(interface: name)) ?? []
            if existing.isEmpty {
                throw ContainerizationError(
                    .internalError,
                    message: "linkAddBridge \(name) failed and bridge does not exist: \(error)"
                )
            }
            log.debug("bridge \(name) already exists")
        }

        // 2. Address (gateway/prefix) on the bridge.
        let cidr = try CIDRv4(gateway, prefix: subnet.prefix)
        do {
            try session.addressAdd(interface: name, ipv4Address: cidr)
        } catch {
            // EEXIST tolerated; netlink layer doesn't expose errno cleanly,
            // so log and continue. linkSet/up below will fail visibly if the
            // bridge state is actually broken.
            log.debug("addressAdd \(cidr) on \(name) returned \(error) (likely already set)")
        }

        // 3. Up + MTU.
        try session.linkSet(interface: name, up: true, mtu: mtu)

        // NAT is opt-in but sticky: once enabled by a previous create(),
        // subsequent create() calls without --enable-nat leave the existing
        // rules and ip_forward state in place. Otherwise `cctl run`
        // (defaults to NAT off) called after `cctl bridge create
        // --enable-nat` would silently disable the NAT the user explicitly
        // turned on. delete() always reverses whatever the state file
        // records.
        let effectiveNAT = enableNAT || (priorState?.natEnabled ?? false)
        guard effectiveNAT else {
            let state = BridgeState(natEnabled: false)
            try state.encode().write(to: stateURL)
            log.info("bridge \(name) ready (subnet \(subnet), NAT disabled)")
            return
        }

        // 4. ip_forward: read what's currently on the host, decide what to
        //    record. If we already have a NAT-enabled state file from a prior
        //    create(), keep its `prevIpForward` (it's the *original* prior
        //    value); otherwise record what we just read.
        let currentIpForward = (try? Self.readSysctl("net/ipv4/ip_forward")) ?? "0"
        let prevIpForward = (priorState?.natEnabled == true ? priorState?.prevIpForward : nil) ?? currentIpForward
        if currentIpForward != "1" {
            try Self.writeSysctl("net/ipv4/ip_forward", value: "1")
        }

        // 5. Egress iface — explicit override or auto-detect.
        let egress: String
        if let explicit = egressInterface {
            egress = explicit
        } else if let detected = HostDefaultRoute.currentEgress() {
            egress = detected
        } else {
            throw ContainerizationError(
                .invalidArgument,
                message: "no default route on host; pass egressInterface explicitly"
            )
        }

        // 6. Record state BEFORE iptables. If a later iptables -A fails,
        //    delete() still has authority to clean up partial rules; if we
        //    deferred the write until after, a mid-failure would orphan rules
        //    with no record.
        let state = BridgeState(
            natEnabled: true,
            prevIpForward: prevIpForward,
            egressInterface: egress
        )
        try state.encode().write(to: stateURL)

        // 7. iptables rules — idempotent. The FORWARD rule is scoped to
        //    `-i <bridge> -o <egress>` so the host doesn't become an
        //    unrestricted router for guest traffic across every host iface
        //    (e.g. a VPN or a sibling bridge).
        try IptablesRules.ensure(
            table: "nat",
            args: [
                "POSTROUTING", "-s", subnet.description, "!", "-o", name, "-j", "MASQUERADE",
            ])
        try IptablesRules.ensure(args: [
            "FORWARD", "-i", name, "-o", egress, "-j", "ACCEPT",
        ])
        try IptablesRules.ensure(args: [
            "FORWARD", "-i", egress, "-o", name, "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT",
        ])

        log.info("bridge \(name) ready (subnet \(subnet), egress \(egress), NAT enabled)")
    }

    private func deleteLocked() throws {
        let stateURL = URL(fileURLWithPath: Self.statePath(for: name))
        let state: BridgeState? = (try? Data(contentsOf: stateURL))
            .flatMap { try? BridgeState.decode($0) }

        // 1. iptables — only if a prior create() with NAT enabled left state
        //    we own. The rules are keyed off subnet, bridge name, and the
        //    recorded egress iface, so removal is precise even when the
        //    host has rules from other tools.
        if let state, state.natEnabled, let egress = state.egressInterface {
            log.debug("removing iptables rules for bridge \(name) (egress \(egress))")
            IptablesRules.remove(
                table: "nat",
                args: [
                    "POSTROUTING", "-s", subnet.description, "!", "-o", name, "-j", "MASQUERADE",
                ])
            IptablesRules.remove(args: [
                "FORWARD", "-i", name, "-o", egress, "-j", "ACCEPT",
            ])
            IptablesRules.remove(args: [
                "FORWARD", "-i", egress, "-o", name, "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT",
            ])
        }

        // 2. Bridge link.
        let session = NetlinkSession(socket: try DefaultNetlinkSocket(), log: log)
        // Refuse to delete anything that isn't actually a bridge — the
        // kernel exposes `/sys/class/net/<iface>/bridge` only for links of
        // kind=bridge, so its presence is an authoritative kind check
        // without parsing IFLA_LINKINFO. This guards against `cctl bridge
        // delete --name eth0` (or docker0, etc.) taking down host links.
        let sysfsBridge = "/sys/class/net/\(name)/bridge"
        let isBridge = FileManager.default.fileExists(atPath: sysfsBridge)
        let exists = !((try? session.linkGet(interface: name)) ?? []).isEmpty
        if exists && !isBridge {
            throw ContainerizationError(
                .invalidArgument,
                message: "refusing to delete \(name): exists but is not a bridge interface"
            )
        }
        do {
            try session.linkDel(name: name)
            log.info("deleted bridge \(name)")
        } catch {
            // ENODEV-like: nothing to do.
            log.debug("linkDel \(name) returned \(error) (likely already absent)")
        }

        // 3. Restore ip_forward only if create()-with-NAT set it from 0.
        if state?.natEnabled == true, state?.prevIpForward == "0" {
            try? Self.writeSysctl("net/ipv4/ip_forward", value: "0")
        }

        // 4. Remove state file.
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: - Paths / sysctl helpers

    private static let stateDir = "/run/containerization"

    private static func statePath(for name: String) -> String {
        "\(stateDir)/bridge-\(name).state"
    }

    private static func lockPath(for name: String) -> String {
        "\(stateDir)/bridge-\(name).lock"
    }

    private static func ensureStateDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: stateDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
    }

    private static func readSysctl(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: "/proc/sys/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeSysctl(_ path: String, value: String) throws {
        let url = URL(fileURLWithPath: "/proc/sys/\(path)")
        try Data((value + "\n").utf8).write(to: url)
    }
}

/// `flock(2)` wrapper. Held for the duration of a closure.
struct FileLock {
    let fd: Int32

    init(path: String) throws {
        let f = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard f >= 0 else {
            throw ContainerizationError(
                .internalError,
                message: "open \(path) failed: errno=\(errno)"
            )
        }
        self.fd = f
    }

    func withExclusive<T>(_ body: () throws -> T) throws -> T {
        guard flock(fd, LOCK_EX) == 0 else {
            close(fd)
            throw ContainerizationError(
                .internalError,
                message: "flock LOCK_EX failed: errno=\(errno)"
            )
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }
}
#endif
