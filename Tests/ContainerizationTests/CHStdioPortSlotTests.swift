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
import ContainerizationOS
import Foundation
import Testing

@testable import Containerization

struct CHStdioPortSlotTests {
    /// The regression this whole design exists for.
    ///
    /// The old `listen(_:)` closed the listening fd and unlinked the socket
    /// file when a stream finished, which permanently killed the port: an
    /// AF_UNIX socket whose last fd is gone answers `connect(2)` with
    /// ECONNREFUSED, and the file cannot be revived in a way cloud-hypervisor
    /// can see. A slot must instead hand off between tenants with the socket
    /// left intact, or a pre-bound pool is a per-VM lifetime budget.
    @Test func slotServesSuccessiveTenantsOnTheSameSocket() async throws {
        let harness = try SlotHarness()
        defer { harness.cleanup() }

        // First tenant: dial, get accepted, finish.
        let first = harness.makeListener()
        try harness.slot.claim(by: first)
        harness.slot.startAcceptingIfNeeded(logger: nil)

        let firstClient = try harness.dial()
        let firstAccepted = try await harness.accept(on: first)
        #expect(firstAccepted != nil)
        try? firstClient.close()
        try first.finish()

        // The socket file must still be there — unlinking it is what turned a
        // "host stopped listening" into the guest's "connection reset".
        #expect(FileManager.default.fileExists(atPath: harness.path.path))

        // Second tenant: same slot, same socket, no rebinding.
        let second = harness.makeListener()
        try harness.slot.claim(by: second)
        harness.slot.startAcceptingIfNeeded(logger: nil)

        let secondClient = try harness.dial()
        let secondAccepted = try await harness.accept(on: second)
        #expect(secondAccepted != nil)
        try? secondClient.close()
        try second.finish()
    }

    /// The cumulative half, without needing a VM: one slot must serve far more
    /// tenants than a pool has ports. The old code gave each tenant its own
    /// socket and destroyed it on finish, so `stdioPoolSize / 3` processes was
    /// the hard ceiling for a VM's entire life.
    @Test func slotServesFarMoreTenantsThanAPoolHasPorts() async throws {
        let harness = try SlotHarness()
        defer { harness.cleanup() }

        for round in 0..<25 {
            let tenant = harness.makeListener()
            try harness.slot.claim(by: tenant)
            harness.slot.startAcceptingIfNeeded(logger: nil)

            let client = try harness.dial()
            let accepted = try await harness.accept(on: tenant)
            #expect(accepted != nil, "tenant \(round) never got its connection")
            try? client.close()
            try tenant.finish()
        }

        #expect(FileManager.default.fileExists(atPath: harness.path.path))
    }

    /// A dial that lands while the port has no tenant — the guest reaching its
    /// `connect(2)` after the host gave up waiting — must be dropped rather
    /// than delivered to the port's next tenant, and must not kill the accept
    /// loop.
    @Test func ownerlessDialIsDroppedAndTheLoopKeepsServing() async throws {
        let harness = try SlotHarness()
        defer { harness.cleanup() }

        let abandoned = harness.makeListener()
        try harness.slot.claim(by: abandoned)
        harness.slot.startAcceptingIfNeeded(logger: nil)
        try abandoned.finish()

        // Late dial with nobody home.
        let straggler = try harness.dial()
        try? await Task.sleep(for: .milliseconds(200))
        try? straggler.close()

        // The next tenant still gets its own connection.
        let next = harness.makeListener()
        try harness.slot.claim(by: next)
        let client = try harness.dial()
        let accepted = try await harness.accept(on: next)
        #expect(accepted != nil)
        try? client.close()
        try next.finish()
    }

    /// Two live listeners on one port would cross-wire two processes' stdio,
    /// so the second claim is a hard error rather than a queue.
    @Test func claimingABusySlotFails() throws {
        let harness = try SlotHarness()
        defer { harness.cleanup() }

        let held = harness.makeListener()
        try harness.slot.claim(by: held)
        #expect(throws: ContainerizationError.self) {
            try harness.slot.claim(by: harness.makeListener())
        }

        // Once released, the slot is claimable again.
        try held.finish()
        try harness.slot.claim(by: harness.makeListener())
    }

    @Test func shutdownRefusesFurtherClaims() throws {
        let harness = try SlotHarness()
        defer { harness.cleanup() }

        harness.slot.shutdown()
        // Idempotent.
        harness.slot.shutdown()
        #expect(throws: ContainerizationError.self) {
            try harness.slot.claim(by: harness.makeListener())
        }
    }
}

/// A slot bound on a real UDS in a temp directory, plus the client side.
private struct SlotHarness {
    static let port: UInt32 = 42

    let directory: URL
    let path: URL
    let slot: CHStdioPortSlot

    init() throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ch-slot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.path = chVsockListenSocketPath(
            baseSocket: directory.appendingPathComponent("vsock.sock"),
            port: Self.port
        )
        let fd = try chVsockBindListener(at: path)
        self.slot = CHStdioPortSlot(port: Self.port, path: path, listenFd: fd)
    }

    func makeListener() -> VsockListener {
        let slot = self.slot
        return VsockListener(port: Self.port) { _ in slot.relinquish() }
    }

    func dial() throws -> Socket {
        let unix = try UnixType(path: path.path)
        let socket = try Socket(type: unix, closeOnDeinit: false)
        do {
            try socket.connect()
        } catch {
            try? socket.close()
            throw error
        }
        return socket
    }

    /// Wait for the accept loop to hand a connection to `listener`. The bound
    /// only exists so a broken loop fails the test instead of hanging it, so
    /// it is generous — the whole suite runs in parallel and scheduling delay
    /// alone can be seconds.
    func accept(on listener: VsockListener) async throws -> FileHandle? {
        try await Timeout.run(seconds: 60) {
            await listener.first(where: { _ in true })
        }
    }

    func cleanup() {
        slot.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
