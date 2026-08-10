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
import CShim
import ContainerizationError
import ContainerizationExtras
import ContainerizationNetlink
import Foundation
import Synchronization

#if canImport(Musl)
import Musl
let osClose = Musl.close
#elseif canImport(Glibc)
import Glibc
let osClose = Glibc.close
#endif

/// A Linux TAP network device whose kernel interface lives only as long as
/// this `TAPDevice` instance. Created via `/dev/net/tun` + `ioctl(TUNSETIFF)`,
/// optionally enslaved to a pre-existing bridge, with MTU/MAC/UP applied via
/// netlink. The fd is held internally; closing it (explicitly or via deinit)
/// removes the interface from the kernel.
///
/// `TUNSETPERSIST` is never called, so process death also cleans up the
/// device automatically. Cloud-hypervisor opens the same TAP **by name**;
/// the held fd keeps the interface alive across CH's open/close cycle.
///
/// Requires `CAP_NET_ADMIN`.
public final class TAPDevice: Sendable {
    /// The kernel-resolved interface name. May differ from the `name`
    /// parameter passed to `init` if the kernel substituted one (e.g. when
    /// `nil` was passed and the kernel picked `tapN`).
    public let name: String

    public let mtu: UInt32

    /// The MAC address as set on init, or nil if the kernel auto-assigned one.
    /// Not read back from the kernel.
    public let macAddress: MACAddress?

    private let _fd: Mutex<Int32?>

    /// Create a TAP device.
    ///
    /// - Parameters:
    ///   - name: Desired interface name. Empty or nil = kernel picks (`tap%d`).
    ///     Length must be < 16 (`IFNAMSIZ - 1`).
    ///   - bridge: Name of an existing bridge to enslave the TAP to, or nil.
    ///   - mtu: MTU in bytes (default 1500).
    ///   - macAddress: Hardware address to set, or nil to leave kernel default.
    public init(
        name: String? = nil,
        bridge: String? = nil,
        mtu: UInt32 = 1500,
        macAddress: MACAddress? = nil
    ) throws {
        if let n = name, n.utf8.count >= 16 {
            throw ContainerizationError(
                .invalidArgument,
                message: "TAP name too long: \(n) (must be < 16 chars)"
            )
        }

        // 1. Open + TUNSETIFF via CShim. Returns fd on success, -errno on failure.
        var resolved = [CChar](repeating: 0, count: 16)
        let fd: Int32 = resolved.withUnsafeMutableBufferPointer { buf in
            (name ?? "").withCString { reqPtr in
                cz_tap_create(reqPtr, buf.baseAddress, 16)
            }
        }
        guard fd >= 0 else {
            throw ContainerizationError(
                .internalError,
                message: "cz_tap_create failed: errno=\(-fd)"
            )
        }

        // From here on, any failure must close `fd` to release the kernel iface.
        var fdToClean: Int32? = fd
        defer {
            if let f = fdToClean {
                _ = osClose(f)
            }
        }

        let resolvedName: String = resolved.withUnsafeBufferPointer { buf in
            // String(cString:) is deprecated in newer toolchains. Build the
            // String from the NUL-terminated UTF-8 bytes directly.
            let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }

        // 2. Apply MAC and master via netlink (single RTM_NEWLINK).
        let session = try NetlinkSession(socket: DefaultNetlinkSocket())
        do {
            try session.linkSetAttributes(
                interface: resolvedName,
                macAddress: macAddress,
                master: bridge
            )
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "linkSetAttributes failed for \(resolvedName): \(error)"
            )
        }

        // 3. Bring UP and set MTU.
        do {
            try session.linkSet(interface: resolvedName, up: true, mtu: mtu)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "linkSet(up:mtu:) failed for \(resolvedName): \(error)"
            )
        }

        // 4. Success — store and clear cleanup.
        self.name = resolvedName
        self.mtu = mtu
        self.macAddress = macAddress
        self._fd = Mutex(fd)
        fdToClean = nil
    }

    /// Close the held fd, removing the interface from the kernel. Idempotent.
    public func close() {
        _fd.withLock { fd in
            if let f = fd {
                _ = osClose(f)
                fd = nil
            }
        }
    }

    deinit {
        close()
    }
}
#endif
